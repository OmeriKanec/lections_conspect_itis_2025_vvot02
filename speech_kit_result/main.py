import json
from io import BytesIO

import requests
import boto3
import logging
import os
import ydb
from fpdf import FPDF

logger = logging.getLogger(__name__)
REGION_NAME = os.getenv("REGION_NAME")

s3_client = boto3.client(
    service_name="s3",
    endpoint_url="https://storage.yandexcloud.net",
    region_name=REGION_NAME,
)


def save_to_ydb(lecture_id, status, error_message, pdf_link):
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
            UPSERT INTO `{table_name}` (id, status, error_message, pdf_link)
            VALUES ('{lecture_id}', '{status}', '{error_message}', '{pdf_link}')
            """,
            commit_tx=True
        )

    pool.retry_operation_sync(execute_upsert)
    driver.stop()
    return True


def save_to_ydb_with_err(lecture_id, error_message):
    save_to_ydb(lecture_id, 'Ошибка', error_message, '')


def save_to_ydb_with_success(lecture_id, status, pdf_link):
    save_to_ydb(lecture_id, status, '', pdf_link)


FONT_PATH = os.getenv("ofont.ru_Gothra.ttf")


def make_pdf(text, buffer, lecture_name):
    pdf = FPDF()
    pdf.add_page()

    pdf.add_font("gothra", style="", fname=FONT_PATH)
    pdf.set_font("gothra", size=14)

    pdf.multi_cell(0, 8, f'Название лекции: {lecture_name}')
    pdf.ln(2)

    pdf.set_font("gothra", size=11)
    pdf.multi_cell(0, 6, text)

    pdf.output(buffer)


def get_text(operation_id, api_key):
    url = "https://stt.api.cloud.yandex.net/stt/v3/getRecognition"
    headers = {"Authorization": f"Api-Key {api_key}"}

    try:
        resp = requests.get(url, headers=headers, params={"operationId": operation_id}, timeout=30, stream=True)
        resp.raise_for_status()
        full_text = ""
        for line in resp.iter_lines():
            if line:
                try:
                    chunk = json.loads(line.decode())
                    result = chunk.get('result', {})

                    final = result.get('final', {})
                    if final.get('alternatives'):
                        text = final['alternatives'][0].get('text', '')
                        full_text += text + " "


                except:
                    continue

        return full_text.strip()

    except requests.exceptions.RequestException as e:
        logger.error("Request error: %s", e)
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "ERROR",
                "error": f"Request failed: {str(e)}"
            })
        }
    except json.JSONDecodeError as e:
        logger.error("JSON decode error: %s", e)
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "ERROR",
                "error": "Invalid JSON response"
            })
        }
    except Exception as e:
        logger.error("Unexpected error: %s", e)
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "ERROR",
                "error": f"Unexpected error: {str(e)}"
            })
        }


def make_lecture_summary(text, api_key, folder_id):
    url = "https://llm.api.cloud.yandex.net/foundationModels/v1/completion"

    headers = {
        "Authorization": f"Api-Key {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "modelUri": f"gpt://{folder_id}/yandexgpt",
        "completionOptions": {"stream": False, "temperature": 0.5, "maxTokens": 2000},
        "messages": [
            {"role": "system",
             "text": "Сделай структурированный конспект лекции на русском. Используй пункты и подзаголовки. Сделай текст удобно переводимым в pdf"},
            {"role": "user", "text": f"Сделай конспект по тексту ниже.\n\nТекст:\n{text}"},
        ],
    }
    resp = requests.post(url, headers=headers, json=payload, timeout=180)
    resp.raise_for_status()
    summary = resp.json()["result"]["alternatives"][0]["message"]["text"]
    return summary


def handler(event, context):
    try:
        messages = event.get("messages", [])
        if not messages:
            return {"statusCode": 200}

        for msg in messages:
            details = msg.get("details", {})
            task = json.loads(details.get("message", {}).get("body", "{}"))
            bucket_name = os.getenv("STORAGE_BUCKET")
            lection_id = task.get('lection_id')
            API_GATEWAY_URL = os.getenv("API_GATEWAY_URL")
            lecture_name = task.get("lecture_name")
            operation_id = task.get('operation_id')
            api_key = os.environ['SPEECHKIT_API_KEY']
            folder_id = os.getenv("FOLDER_ID")
            text = get_text(operation_id, api_key)
            summary = make_lecture_summary(text, api_key, folder_id)
            logger.info("lection_id: %s", lection_id)
            pdf_key = f"{lection_id}-summary.pdf"
            pdf_buffer = BytesIO()
            pdf_buffer.seek(0)
            make_pdf(summary, pdf_buffer, lecture_name)
            s3_client.put_object(
                Bucket=bucket_name,
                Key=pdf_key,
                Body=pdf_buffer,
                ContentType="application/pdf"
            )
            audio_key = task.get('audio_key')
            if audio_key:
                s3_client.delete_object(
                    Bucket=bucket_name,
                    Key=audio_key
                )
            save_to_ydb_with_success(lection_id, "Успешно завершено", f"{API_GATEWAY_URL}/pdf/{pdf_key}")




    except Exception as e:
        logger.error("Error: %s", str(e))
        return {"statusCode": 500, "body": str(e)}

# # Тестовая функция
# def test_check_status():
#     """Для локального тестирования"""
#     api_key = "AQVN0P-KutE3VCkBTxeby9Df3ABC1AAQv-TOtrdV"
#     if not api_key:
#         print("Set SPEECHKIT_API_KEY env var")
#         return
#
#     # Пример вызова
#     result = get_text(
#         operation_id="f8dogit5lu4cish8dpnt",
#         api_key=api_key
#     )
#     print(json.dumps(result, indent=2, ensure_ascii=False))
#
#
# if __name__ == "__main__":
#     test_check_status()
