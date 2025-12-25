import os
import json
import logging
import boto3
import requests
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

STORAGE_BUCKET = os.getenv("STORAGE_BUCKET")
REGION_NAME = os.getenv("REGION_NAME")

s3_client = boto3.client(
    service_name="s3",
    endpoint_url="https://storage.yandexcloud.net",
    region_name=REGION_NAME,
)


def get_file_path(public_key):
    url = "https://cloud-api.yandex.net/v1/disk/public/resources/download"
    resp = requests.get(url, params={"public_key": public_key}, timeout=1200)
    if resp.ok:
        return resp.json()['href']
    logger.error("getFile failed: %s", resp.text)
    return None

def download_video(file_href):
    url = file_href
    resp = requests.get(url, timeout=120)
    if resp.ok:
        logger.info("Downloaded %d bytes", len(resp.content))
        return resp.content
    logger.error("Download failed: %s", resp.status_code)
    return None


def upload_video(video_data, id):
    key = f"{id}.mp4"

    try:
        s3_client.put_object(
            Bucket=STORAGE_BUCKET,
            Key=key,
            Body=video_data,
            ContentType="video/mp4",
            Metadata={"source": "yandex disk"}
        )
        logger.info("Saved to: %s/%s", STORAGE_BUCKET, key)
        return key
    except ClientError as e:
        logger.error("Upload failed: %s", e)
        return None


# def send_public_link(chat_id, key):
#     public_url = f"https://{API_GATEWAY_DOMAIN}/video/{key}"
#     message = f"«Видео доступно по URL: {public_url}»"
#
#     url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
#     requests.post(url, json={
#         "chat_id": chat_id,
#         "text": message,
#         "disable_web_page_preview": True
#     }, timeout=10)
#     logger.info("Sent URL: %s", public_url)
#     return public_url


def handler(event, context):
    messages = event.get("messages", [])
    if not messages:
        return {"statusCode": 200}

    for msg in messages:
        details = msg.get("details", {})
        task = json.loads(details.get("message", {}).get("body", "{}"))

        public_key = task.get("public_key")
        lection_id = task.get("lection_id")
        lecture_name = task.get("lecture_name")

        file_href = get_file_path(public_key)

        video_data = download_video(file_href)

        key = upload_video(video_data, lection_id)

        # send_public_link(chat_id, key)

    return {"statusCode": 200, "body": "done"}
