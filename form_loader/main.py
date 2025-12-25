import os


def handler(event, context):
    html_path = 'form.html'

    if os.path.exists(html_path):
        with open(html_path, 'r', encoding='utf-8') as f:
            html_content = f.read()

    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'text/html; charset=utf-8'
        },
        'isBase64Encoded': False,
        'body': html_content
    }
