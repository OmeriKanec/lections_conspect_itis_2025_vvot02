import os
from datetime import datetime

import ydb
import ydb.iam


def get_from_ydb():
    driver = ydb.Driver(
        endpoint=os.getenv('YDB_ENDPOINT'),
        database=os.getenv('YDB_DATABASE'),
        credentials=ydb.iam.MetadataUrlCredentials()
    )

    table_name = os.getenv('YDB_TABLE_NAME')
    driver.wait(fail_fast=True)
    pool = ydb.SessionPool(driver)

    def execute_select(session):
        return session.transaction(ydb.SerializableReadWrite()).execute(
            f"""
            SELECT id, created_at, title, public_url, status, pdf_link, error_message
            FROM {table_name}
            ORDER BY created_at DESC
            """
        )

    result = pool.retry_operation_sync(execute_select)
    driver.stop()
    return result


def handler(event, context):
    result = get_from_ydb()

    tasks = []
    if result and len(result) > 0 and result[0] and result[0].rows:
        for row in result[0].rows:
            try:
                if hasattr(row.created_at, 'strftime'):
                    created_at_str = row.created_at.strftime('%Y-%m-%d %H:%M:%S')
                else:
                    timestamp_val = float(row.created_at)
                    if timestamp_val > 1e10:
                        created_at_str = datetime.fromtimestamp(timestamp_val / 1_000_000).strftime('%Y-%m-%d %H:%M:%S')
                    else:
                        created_at_str = datetime.fromtimestamp(timestamp_val).strftime('%Y-%m-%d %H:%M:%S')
            except:
                created_at_str = 'N/A'
            tasks.append({
                'id': row.id,
                'created_at': created_at_str,
                'title': row.title,
                'public_url': row.public_url,
                'status': row.status,
                'pdf_link': row.pdf_link,
                'error_message': row.error_message
            })

    with open('template.html', 'r', encoding='utf-8') as f:
        html_template = f.read()

    html_content = html_template.format(
        tasks_rows=generate_tasks_rows(tasks)
    )

    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-cache'
        },
        'body': html_content
    }


def generate_tasks_rows(tasks):
    if not tasks:
        return '<tr><td colspan="7" class="empty-state">Нет заданий</td></tr>'

    rows = ''
    for task in tasks:
        status_class = task['status'].lower().replace(' ', '-').replace('«', '').replace('»', '')
        pdf_link = ''
        error_cell = ''

        if task['status'] == 'Успешно завершено' and task['pdf_link']:
            pdf_link = f'<a href="{task["pdf_link"]}" class="download-link" download>Скачать PDF</a>'

        if task['status'] == 'Ошибка' and task['error_message']:
            error_cell = f'<span class="error-message">{task["error_message"]}</span>'

        rows += f'''
            <tr class="status-{status_class}">
                <td>{task['created_at']}</td>
                <td>{task['id']}</td>
                <td>{task['title']}</td>
                <td><a href="{task["public_url"]}" target="_blank">Открыть</a></td>
                <td>{task['status']}</td>
                <td>{pdf_link}</td>
                <td>{error_cell}</td>
            </tr>'''

    return rows
