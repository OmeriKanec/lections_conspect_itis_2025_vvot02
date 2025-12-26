import json
import logging
import base64
import os
import uuid
from typing import Dict, Any
from urllib.parse import parse_qs
import requests
import boto3
import ydb

DOWNLOADER_QUEUE_URL = os.getenv("DOWNLOADER_QUEUE_URL")
REGION_NAME = os.getenv("REGION_NAME")

mq_client = boto3.client(
    service_name="sqs",
    endpoint_url="https://message-queue.api.cloud.yandex.net",
    region_name=REGION_NAME,
)


def save_to_ydb(lecture_id, status, title, error_flag):
    driver = ydb.Driver(
        endpoint=os.getenv('YDB_ENDPOINT'),
        database=os.getenv('YDB_DATABASE'),
        credentials=ydb.iam.MetadataUrlCredentials()
    )

    table_name = os.getenv('YDB_TABLE_NAME')

    driver.wait(fail_fast=True)

    pool = ydb.SessionPool(driver)

    def execute_upsert(session):
        # Я оставлю это здесь как напоминание о потерянном из-за бага(скорее всего) времени
        # С параметрами не работает
        # parameters = {
        #     '$id': ydb.TypedValue(lecture_id, ydb.PrimitiveType.Utf8),
        #     '$status': ydb.TypedValue(status, ydb.PrimitiveType.Utf8),
        #     '$title': ydb.TypedValue(title, ydb.PrimitiveType.Utf8),
        #     '$error_flag': ydb.TypedValue(error_flag, ydb.PrimitiveType.Bool)
        # }
        session.transaction(ydb.SerializableReadWrite()).execute(
            f"""
            UPSERT INTO `{table_name}` (id, status, title, error_flag, created_at)
            VALUES ('{lecture_id}', '{status}', '{title}', {error_flag}, CurrentUtcTimestamp())
            """,
            commit_tx=True
        )

    pool.retry_operation_sync(execute_upsert)
    driver.stop()
    return True


def handler(event: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
    global form_data
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    logger.info(f"Request received: {event}")

    if 'body' in event:
        body_str = event['body']

        if event.get('isBase64Encoded', False):
            body_bytes = base64.b64decode(body_str)
            body_str = body_bytes.decode('utf-8')
        params = parse_qs(body_str)
        form_data = {k: v[0] if v else '' for k, v in params.items()}

    processed_data = {
        'lecture_name': form_data.get('lecture_name', ''),
        'video_url': form_data.get('video_url', ''),
    }

    logger.info(f"Form processed: {processed_data}")

    url = "https://cloud-api.yandex.net/v1/disk/public/resources"
    lection_id = str(uuid.uuid4())
    lecture_name = processed_data.get("lecture_name")
    resp = requests.get(url, params={"public_key": processed_data.get('video_url')}, timeout=10)
    logger.info(f"Gotten response: {resp}")
    if resp.ok:
        if resp.json()["mime_type"] != "video/mp4":
            save_to_ydb(lection_id, 'Only video accepted', lecture_name, True)
        else:
            task = {
                "public_key": processed_data.get('video_url'),
                "lection_id": lection_id,
                "lecture_name": lecture_name,
            }

            mq_client.send_message(
                QueueUrl=DOWNLOADER_QUEUE_URL,
                MessageBody=json.dumps(task)
            )
            save_to_ydb(lection_id, 'Processing...', lecture_name, False)
    else:
        save_to_ydb(lection_id, 'Not correct link', lecture_name, True)
    return {
        'statusCode': 302,
        'headers': {
            'Location': '/',
            'Access-Control-Allow-Origin': '*'
        },
        'body': ''
    }
