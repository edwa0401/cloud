"""
CafeChatbotFunction — Lambda handler for the Cafe AI Order Assistant.

Reads live menu data from the lab's RDS MariaDB instance, grounds an
Amazon Bedrock (Converse API) prompt in that data, and returns a reply
to the chat widget embedded in the cafe web app.

Environment variables (set on the Lambda function):
  BEDROCK_MODEL_ID  e.g. "anthropic.claude-3-5-haiku-20241022-v1:0"
  DB_SECRET_ARN     ARN of the Secrets Manager secret holding
                     {"username": "...", "password": "...", "host": "..."}

Requires the pymysql package bundled in the deployment zip (see
README.md step 5) since it is not part of the base Lambda runtime.
"""

import json
import os

import boto3
import pymysql

REGION = os.environ.get("AWS_REGION", "us-east-1")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-5-haiku-20241022-v1:0")
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
DB_NAME = os.environ.get("DB_NAME", "cafe_db")
DB_TABLE = os.environ.get("DB_TABLE", "menu_items")

bedrock = boto3.client("bedrock-runtime", region_name=REGION)
secrets = boto3.client("secretsmanager", region_name=REGION)

# Reused across warm invocations of the same execution environment.
_menu_cache = {"items": None}


def get_db_credentials():
    resp = secrets.get_secret_value(SecretId=DB_SECRET_ARN)
    return json.loads(resp["SecretString"])


def fetch_menu():
    if _menu_cache["items"] is not None:
        return _menu_cache["items"]

    creds = get_db_credentials()
    conn = pymysql.connect(
        host=creds["host"],
        user=creds["username"],
        password=creds["password"],
        database=DB_NAME,
        connect_timeout=5,
    )
    try:
        with conn.cursor() as cur:
            cur.execute(f"SELECT name, description, price FROM {DB_TABLE}")
            rows = cur.fetchall()
            _menu_cache["items"] = rows
            return rows
    finally:
        conn.close()


def build_system_prompt(menu_rows):
    lines = [f"- {name}: {desc} (${float(price):.2f})" for name, desc, price in menu_rows]
    menu_text = "\n".join(lines) if lines else "(menu is currently empty)"
    return (
        "You are the Cafe Order Assistant for a small cafe's website. "
        "Answer customer questions about the menu, prices, and dietary "
        "basics, and make friendly recommendations. Be concise (2-4 "
        "sentences). Only use the menu data below — if something isn't "
        "on it, say it's not on the current menu rather than guessing.\n\n"
        f"Current menu:\n{menu_text}"
    )


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
        user_message = (body.get("message") or "").strip()
        if not user_message:
            return _response(400, {"error": "message is required"})
        if len(user_message) > 1000:
            return _response(400, {"error": "message is too long"})

        menu_rows = fetch_menu()
        system_prompt = build_system_prompt(menu_rows)

        result = bedrock.converse(
            modelId=MODEL_ID,
            system=[{"text": system_prompt}],
            messages=[{"role": "user", "content": [{"text": user_message}]}],
            inferenceConfig={"maxTokens": 400, "temperature": 0.4},
        )
        reply = result["output"]["message"]["content"][0]["text"]
        return _response(200, {"reply": reply})

    except Exception as exc:  # noqa: BLE001 - return a safe message, log the real error
        print(f"ERROR: {exc}")
        return _response(500, {"error": "Something went wrong. Please try again."})


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            # Loosen for local testing; scope this to the cafe app's
            # actual origin before using this outside a lab/demo.
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }
