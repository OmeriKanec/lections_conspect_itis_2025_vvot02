import json
import os

import boto3
import requests
import logging

import ydb

logger = logging.getLogger()
logger.setLevel(logging.INFO)
REGION_NAME = os.getenv("REGION_NAME")
SPEECH_KIT_QUEUE_URL = os.getenv("SPEECH_KIT_QUEUE_ID_URL")

mq_client = boto3.client(
    service_name="sqs",
    endpoint_url="https://message-queue.api.cloud.yandex.net",
    region_name=REGION_NAME,
)
def save_to_ydb(lecture_id, status, error_message):
    driver = ydb.Driver(
        endpoint=os.getenv('YDB_ENDPOINT'),
        database=os.getenv('YDB_DATABASE'),
        credentials=ydb.iam.MetadataUrlCredentials()
    )

    table_name = os.getenv('YDB_TABLE_NAME')

    driver.wait(fail_fast=True)

    pool = ydb.SessionPool(driver)

    def execute_upsert(session):
        session.transaction(ydb.SerializableReadWrite()).execute(
            f"""
            UPSERT INTO `{table_name}` (id, status, error_message)
            VALUES ('{lecture_id}', '{status}', '{error_message}')
            """,
            commit_tx=True
        )

    pool.retry_operation_sync(execute_upsert)
    driver.stop()
    return True


def save_to_ydb_with_err(lecture_id, error_message):
    save_to_ydb(lecture_id, 'Ошибка', error_message)


def save_to_ydb_with_success(lecture_id, status):
    save_to_ydb(lecture_id, status, '')


def handler(event, context):
    global lection_id
    try:
        messages = event.get("messages", [])
        if not messages:
            return {"statusCode": 200}

        for msg in messages:
            details = msg.get("details", {})
            task = json.loads(details.get("message", {}).get("body", "{}"))
            bucket_name = os.getenv("STORAGE_BUCKET")
            lection_id = task.get('lection_id')
            lecture_name = task.get("lecture_name")
            audio_key = task.get('key')
            if not audio_key:
                return {"statusCode": 400, "body": "Missing 'key'"}

            audio_uri = f"https://storage.yandexcloud.net/{bucket_name}/{audio_key}"
            api_key = os.environ['SPEECHKIT_API_KEY']

            stt_url = "https://stt.api.cloud.yandex.net/stt/v3/recognizeFileAsync"
            headers = {
                "Authorization": f"Api-Key {api_key}",
                "Content-Type": "application/json"
            }
            payload = {
                "uri": audio_uri,
                "recognitionModel": {
                    "model": "general",
                    "audioFormat": {
                        "containerAudio": {
                            "containerAudioType": "MP3"
                        }
                    }
                }
            }

            resp = requests.post(stt_url, headers=headers, json=payload)
            operation = resp.json()
            operation_id = operation['id']
            logger.info("Started recognition: %s", operation_id)
            task = {
                "lection_id": lection_id,
                "operation_id": operation_id,
                "lecture_name": lecture_name,
                "audio_key": audio_key
            }

            mq_client.send_message(
                QueueUrl=SPEECH_KIT_QUEUE_URL,
                MessageBody=json.dumps(task),
                DelaySeconds=200
            )



    except Exception as e:
        logger.error("Error: %s", str(e))
        save_to_ydb_with_err(lection_id, 'Speech recognition failed')
        return {"statusCode": 500, "body": str(e)}
