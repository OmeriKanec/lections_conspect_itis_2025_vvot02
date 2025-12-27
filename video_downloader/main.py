import os
import json
import logging
import subprocess
import tarfile

import boto3
import requests
import ydb
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

STORAGE_BUCKET = os.getenv("STORAGE_BUCKET")
REGION_NAME = os.getenv("REGION_NAME")
SPEECH_KIT_QUEUE_URL = os.getenv("SPEECH_KIT_QUEUE_URL")

s3_client = boto3.client(
    service_name="s3",
    endpoint_url="https://storage.yandexcloud.net",
    region_name=REGION_NAME,
)


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


def get_file_path(public_key):
    url = "https://cloud-api.yandex.net/v1/disk/public/resources/download"
    resp = requests.get(url, params={"public_key": public_key}, timeout=1200)
    if resp.ok:
        return resp.json()['href']
    logger.error("getFile failed: %s", resp.text)
    return None


def extract_audio_streaming(file_href):
    """FFmpeg читает видео ПОТОЧНО из URL"""

    # FFmpeg из /tmp/
    ffmpeg_exe = "/tmp/ffmpeg"
    if not os.path.exists(ffmpeg_exe):
        with tarfile.open("./ffmpeg.tar.gz", "r:gz") as tar:
            tar.extractall("/tmp/")

    output_file = "/tmp/audio.mp3"
    cmd = [
        ffmpeg_exe, "-y",
        "-i", file_href,  # ← URL напрямую!
        "-vn",  # без видео
        "-acodec", "libmp3lame",  # MP3
        "-q:a", "2",  # качество
        "-ar", "44100", "-ac", "2",
        output_file
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)

    if result.returncode != 0:
        logger.error("FFmpeg: %s", result.stderr)
        return "Extraction failed"

    with open(output_file, "rb") as f:
        audio_data = f.read()

    os.unlink(output_file)
    logger.info("Audio extracted: %d bytes", len(audio_data))
    return audio_data

def upload_audio(audio_data, lection_id):
    key = f"{lection_id}.mp3"

    try:
        s3_client.put_object(
            Bucket=STORAGE_BUCKET,
            Key=key,
            Body=audio_data,
            ContentType="audio/mpeg",
            Metadata={"source": "yandex disk"}
        )
        logger.info("Saved to: %s/%s", STORAGE_BUCKET, key)
        return key
    except ClientError as e:
        logger.error("Upload failed: %s", e)
        return None



def handler(event, context):
    messages = event.get("messages", [])
    if not messages:
        return {"statusCode": 200}

    for msg in messages:
        details = msg.get("details", {})
        task = json.loads(details.get("message", {}).get("body", "{}"))

        public_key = task.get("public_key")
        lecture_name = task.get("lecture_name")
        lection_id = task.get("lection_id")

        file_href = get_file_path(public_key)


        audio_data = extract_audio_streaming(file_href)
        if audio_data == "Extraction failed":
            save_to_ydb_with_err(lection_id, audio_data)

        key = upload_audio(audio_data, lection_id)

        task = {
            "lection_id": lection_id,
            "key": key,
            "lecture_name": lecture_name
        }
        mq_client.send_message(
            QueueUrl=SPEECH_KIT_QUEUE_URL,
            MessageBody=json.dumps(task)
        )
        save_to_ydb_with_success(lection_id, "В обработке")

    return {"statusCode": 200, "body": "done"}
