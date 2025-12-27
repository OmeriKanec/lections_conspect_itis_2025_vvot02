variable "cloud_id" {
  description = "Yandex Cloud ID"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "region" {
  description = "Region"
  type        = string
}

variable "prefix" {
  type        = string
  description = "Prefix for all resource names (prefix-name)"
}

terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.175.0"
    }
    archive = {
      source = "hashicorp/archive"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
}

# Создание сервисного аккаунта и назначение ему ролей
# Сервисный аккаунт
resource "yandex_iam_service_account" "lection_sa" {
  name        = "${var.prefix}-lection-sa"
  description = "Service account for Telegram video bot (Cloud Functions, MQ, Object Storage)"
}

# storage.editor — доступ к Object Storage
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_storage" {
  folder_id  = var.folder_id
  role       = "storage.editor"
  member     = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

# ymq.reader — чтение сообщений из очередей
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_ymq_reader" {
  folder_id  = var.folder_id
  role       = "ymq.reader"
  member     = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

# ymq.writer — запись сообщений в очереди
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_ymq_writer" {
  folder_id  = var.folder_id
  role       = "ymq.writer"
  member     = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

# functions.invoker — право вызывать функции
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_functions_invoker" {
  folder_id  = var.folder_id
  role       = "functions.functionInvoker"
  member     = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

resource "yandex_resourcemanager_folder_iam_member" "lection_sa_ydb_admin" {
  folder_id  = var.folder_id
  role       = "ydb.admin"
  member     = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

resource "yandex_resourcemanager_folder_iam_member" "lection_sa_ai_speechkit_stt_user" {
  folder_id  = var.folder_id
  role       = "ai.speechkit-stt.user"
  member     = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

resource "yandex_resourcemanager_folder_iam_member" "lection_sa_gpt_api" {
  folder_id = var.folder_id
  role      = "ai.languageModels.user"
  member     = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

resource "yandex_iam_service_account_api_key" "speechkit_key" {
  service_account_id = yandex_iam_service_account.lection_sa.id
  description        = "API key for SpeechKit functions"
}

# Ключ доступа
resource "yandex_iam_service_account_static_access_key" "sa_static_key" {
  service_account_id = yandex_iam_service_account.lection_sa.id
  description        = "Access key for vvot02"
  depends_on         = [yandex_resourcemanager_folder_iam_member.lection_sa_storage]
}


resource "yandex_iam_service_account" "ymq_admin" {
  name = "${var.prefix}-ymq-admin"
}

resource "yandex_resourcemanager_folder_iam_member" "ymq_admin_role" {
  folder_id  = var.folder_id
  role       = "ymq.admin"
  member     = "serviceAccount:${yandex_iam_service_account.ymq_admin.id}"
  depends_on = [yandex_iam_service_account.ymq_admin]
}

resource "yandex_iam_service_account_static_access_key" "ymq_admin" {
  service_account_id = yandex_iam_service_account.ymq_admin.id
  depends_on         = [yandex_resourcemanager_folder_iam_member.ymq_admin_role]
}

locals {
  ymq_admin_access_key = yandex_iam_service_account_static_access_key.ymq_admin.access_key
  ymq_admin_secret_key = yandex_iam_service_account_static_access_key.ymq_admin.secret_key
}


resource "time_sleep" "iam_replication" {
  depends_on      = [yandex_iam_service_account.ymq_admin, yandex_iam_service_account.lection_sa]
  create_duration = "12s"
}


# Бакет
resource "yandex_storage_bucket" "lection" {
  bucket        = "${var.prefix}-tg-video"
  folder_id     = var.folder_id
  force_destroy = true
  depends_on    = [yandex_iam_service_account.lection_sa]
}


# Создание и настройка Api Gateway
resource "yandex_api_gateway" "vvot02_api_gw" {
  name              = "${var.prefix}-api-gw"
  description       = "Telegram video bot webhook API Gateway"
  execution_timeout = "30"
  spec              = templatefile("${path.module}/api_gateway.yaml", {
    FOLDER_ID          = var.folder_id
    SA_ID                      = yandex_iam_service_account.lection_sa.id
    FORM_LOADER_FUNCTION_ID    = yandex_function.form_loader.id
    FORM_PROCESSOR_FUNCTION_ID = yandex_function.form_processor.id
    BUCKET       = yandex_storage_bucket.lection.bucket
    TASKS_LOADER_FUNCTION_ID = yandex_function.tasks_loader.id
  })

}

output "api_gateway_url" {
  value       = "https://${yandex_api_gateway.vvot02_api_gw.domain}"
  description = "API Gateway URL"
}


resource "yandex_function" "form_loader" {
  name        = "${var.prefix}-form-loader"
  folder_id   = var.folder_id
  description = "Receives Video, downloads it, sends it to bucket"

  entrypoint         = "main.handler"
  runtime            = "python39"
  memory             = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout  = "30"
  environment        = {
    REGION_NAME = var.region
  }

  content {
    zip_filename = data.archive_file.form_loader_zip.output_path
  }
  user_hash = data.archive_file.form_loader_zip.output_sha256
}

data "archive_file" "form_loader_zip" {

  type        = "zip"
  source_dir  = "${path.module}/form_loader"
  output_path = "${path.module}/form_loader.zip"
}

resource "yandex_function" "form_processor" {
  name        = "${var.prefix}-form-processor"
  folder_id   = var.folder_id
  description = "Receives Video, downloads it, sends it to bucket"

  entrypoint         = "main.handler"
  runtime            = "python39"
  memory             = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout  = "30"
  environment        = {
    REGION_NAME           = var.region
    DOWNLOADER_QUEUE_URL  = yandex_message_queue.downloader_queue.id
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
    YDB_ENDPOINT          = "grpcs://ydb.serverless.yandexcloud.net:2135" # yandex_ydb_database_serverless.ydb.ydb_api_endpoint не работает
    YDB_DATABASE          = yandex_ydb_database_serverless.ydb.database_path
    YDB_TABLE_NAME        = yandex_ydb_table.tasks_table.path
  }

  content {
    zip_filename = data.archive_file.form_processor_zip.output_path
  }
  user_hash = data.archive_file.form_processor_zip.output_sha256
}

data "archive_file" "form_processor_zip" {

  type        = "zip"
  source_dir  = "${path.module}/form_processor"
  output_path = "${path.module}/form_processor.zip"
}


# База данных
resource "yandex_ydb_database_serverless" "ydb" {
  name      = "${var.prefix}-ydb-serverless"
  folder_id = var.folder_id
  serverless_database {
    storage_size_limit = 1
  }
}

resource "time_sleep" "db_replication" {
  depends_on      = [yandex_ydb_database_serverless.ydb, yandex_iam_service_account.lection_sa]
  create_duration = "20s"
}

resource "yandex_ydb_table" "tasks_table" {
  path = "tasks"

  connection_string = yandex_ydb_database_serverless.ydb.ydb_full_endpoint
  depends_on        = [time_sleep.db_replication, yandex_ydb_database_serverless.ydb]
  primary_key       = ["id"]

  column {
    name = "id"
    type = "Utf8"
  }
  column {
    name = "status"
    type = "Utf8"
  }
  column {
    name = "pdf_link"
    type = "Utf8"
  }
  column {
    name = "title"
    type = "Utf8"
  }
  column {
    name = "error_message"
    type = "Utf8"
  }
  column {
    name = "public_url"
    type = "Utf8"
  }

  column {
    name = "created_at"
    type = "Timestamp"
  }


}


# Очередь на загрузку видео
resource "yandex_message_queue" "downloader_queue" {
  name                       = "${var.prefix}-queue-downloader"
  visibility_timeout_seconds = "1200"
  message_retention_seconds  = "604800"
  receive_wait_time_seconds  = "20"
  access_key                 = local.ymq_admin_access_key
  secret_key                 = local.ymq_admin_secret_key
  depends_on                 = [
    yandex_iam_service_account.ymq_admin,
    time_sleep.iam_replication
  ]
}

resource "yandex_storage_object" "function_archive" {
  bucket      = yandex_storage_bucket.lection.bucket
  key         = "function.zip"
  source      = data.archive_file.video_downloader_zip.output_path
  source_hash = data.archive_file.video_downloader_zip.output_sha256
}

resource "yandex_function" "downloader" {
  name        = "${var.prefix}-func-downloader"
  folder_id   = var.folder_id
  description = "Receives Video, downloads it, sends it to bucket"

  entrypoint         = "main.handler"
  runtime            = "python39"
  memory             = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout  = "300"
  environment        = {
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
    STORAGE_BUCKET        = yandex_storage_bucket.lection.bucket
    REGION_NAME           = var.region
    YDB_ENDPOINT          = "grpcs://ydb.serverless.yandexcloud.net:2135"
    # yandex_ydb_database_serverless.ydb.ydb_api_endpoint не работает
    YDB_DATABASE          = yandex_ydb_database_serverless.ydb.database_path
    YDB_TABLE_NAME        = yandex_ydb_table.tasks_table.path
    SPEECH_KIT_QUEUE_URL  = yandex_message_queue.speech_kit_activation_queue.id
  }

  package {
    bucket_name = yandex_storage_bucket.lection.bucket
    object_name = yandex_storage_object.function_archive.key
    sha_256     = ""
  }
  user_hash  = data.archive_file.video_downloader_zip.output_sha256
  depends_on = [yandex_storage_object.function_archive]
}

data "archive_file" "video_downloader_zip" {

  type        = "zip"
  source_dir  = "${path.module}/video_downloader"
  output_path = "${path.module}/video_downloader.zip"
}

resource "yandex_function_trigger" "downloader_trigger" {
  name = "${var.prefix}-trigger-downloader"
  function {
    id                 = yandex_function.downloader.id
    service_account_id = yandex_iam_service_account.lection_sa.id
  }

  message_queue {
    queue_id           = yandex_message_queue.downloader_queue.arn
    service_account_id = yandex_iam_service_account.lection_sa.id
    batch_size         = "1"
    batch_cutoff       = "10"
  }

  depends_on = [
    yandex_function.downloader,
    yandex_message_queue.downloader_queue
  ]

}


resource "yandex_function" "speech_kit_activator" {
  name        = "${var.prefix}-speech-kit-activator"
  folder_id   = var.folder_id
  description = "Sends link to audio to speech kit"

  entrypoint         = "main.handler"
  runtime            = "python39"
  memory             = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout  = "30"
  environment        = {
    REGION_NAME             = var.region
    SPEECH_KIT_QUEUE_ID_URL = yandex_message_queue.speech_kit_result_queue.id
    YDB_ENDPOINT            = "grpcs://ydb.serverless.yandexcloud.net:2135"
    # yandex_ydb_database_serverless.ydb.ydb_api_endpoint не работает
    YDB_DATABASE            = yandex_ydb_database_serverless.ydb.database_path
    YDB_TABLE_NAME          = yandex_ydb_table.tasks_table.path
    SPEECHKIT_API_KEY       = yandex_iam_service_account_api_key.speechkit_key.secret_key
    STORAGE_BUCKET          = yandex_storage_bucket.lection.bucket
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
  }

  content {
    zip_filename = data.archive_file.speech_kit_activator_zip.output_path
  }
  user_hash = data.archive_file.speech_kit_activator_zip.output_sha256
}

data "archive_file" "speech_kit_activator_zip" {

  type        = "zip"
  source_dir  = "${path.module}/speech_kit_activator"
  output_path = "${path.module}/speech_kit_activator.zip"
}

resource "yandex_message_queue" "speech_kit_activation_queue" {
  name                       = "${var.prefix}-speech-kit-activation-queue"
  visibility_timeout_seconds = "1200"
  message_retention_seconds  = "604800"
  receive_wait_time_seconds  = "20"
  access_key                 = local.ymq_admin_access_key
  secret_key                 = local.ymq_admin_secret_key
  depends_on                 = [
    yandex_iam_service_account.ymq_admin,
    time_sleep.iam_replication
  ]
}

resource "yandex_function_trigger" "speech_kit_activator_trigger" {
  name = "${var.prefix}-speech-kit-activator-trigger"
  function {
    id                 = yandex_function.speech_kit_activator.id
    service_account_id = yandex_iam_service_account.lection_sa.id
  }

  message_queue {
    queue_id           = yandex_message_queue.speech_kit_activation_queue.arn
    service_account_id = yandex_iam_service_account.lection_sa.id
    batch_size         = "1"
    batch_cutoff       = "10"
  }

  depends_on = [
    yandex_function.speech_kit_activator,
    yandex_message_queue.speech_kit_activation_queue
  ]

}


resource "yandex_message_queue" "speech_kit_result_queue" {
  name                       = "${var.prefix}-speech-kit-result-queue"
  visibility_timeout_seconds = "1200"
  message_retention_seconds  = "604800"
  receive_wait_time_seconds  = "20"
  access_key                 = local.ymq_admin_access_key
  secret_key                 = local.ymq_admin_secret_key
  depends_on                 = [
    yandex_iam_service_account.ymq_admin,
    time_sleep.iam_replication
  ]
}

resource "yandex_function" "speech_kit_result" {
  name        = "${var.prefix}-speech-kit-result"
  folder_id   = var.folder_id
  description = "Gets result from speech kit, sends it to gpt and saves result to pdf"

  entrypoint  = "main.handler"
  runtime     = "python39"
  memory      = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout = "30"
  environment = {
    REGION_NAME = var.region
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
    YDB_ENDPOINT  = "grpcs://ydb.serverless.yandexcloud.net:2135" # yandex_ydb_database_serverless.ydb.ydb_api_endpoint не работает
    YDB_DATABASE  = yandex_ydb_database_serverless.ydb.database_path
    YDB_TABLE_NAME = yandex_ydb_table.tasks_table.path
    STORAGE_BUCKET = yandex_storage_bucket.lection.bucket
    SPEECHKIT_API_KEY = yandex_iam_service_account_api_key.speechkit_key.secret_key
    FOLDER_ID = var.folder_id
    API_GATEWAY_URL = "https://${yandex_api_gateway.vvot02_api_gw.domain}"
  }

  content {
    zip_filename = data.archive_file.speech_kit_result_zip.output_path
  }
  user_hash = data.archive_file.speech_kit_result_zip.output_sha256
}

data "archive_file" "speech_kit_result_zip" {

  type        = "zip"
  source_dir  = "${path.module}/speech_kit_result"
  output_path = "${path.module}/speech_kit_result.zip"
}

resource "yandex_function_trigger" "speech_kit_result_trigger" {
  name = "${var.prefix}-speech-kit-result-trigger"
  function {
    id                 = yandex_function.speech_kit_result.id
    service_account_id = yandex_iam_service_account.lection_sa.id
  }

  message_queue {
    queue_id           = yandex_message_queue.speech_kit_result_queue.arn
    service_account_id = yandex_iam_service_account.lection_sa.id
    batch_size         = "1"
    batch_cutoff       = "10"
  }

  depends_on = [
    yandex_function.speech_kit_result,
    yandex_message_queue.speech_kit_result_queue
  ]

}

resource "yandex_function" "tasks_loader" {
  name        = "${var.prefix}-tasks-loader"
  folder_id   = var.folder_id
  description = "Loads html with tasks"

  entrypoint  = "main.handler"
  runtime     = "python39"
  memory      = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout = "30"
  environment = {
    REGION_NAME = var.region
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
    YDB_ENDPOINT  = "grpcs://ydb.serverless.yandexcloud.net:2135" # yandex_ydb_database_serverless.ydb.ydb_api_endpoint не работает
    YDB_DATABASE  = yandex_ydb_database_serverless.ydb.database_path
    YDB_TABLE_NAME = yandex_ydb_table.tasks_table.path
    STORAGE_BUCKET = yandex_storage_bucket.lection.bucket
  }

  content {
    zip_filename = data.archive_file.tasks_loader_zip.output_path
  }
  user_hash = data.archive_file.tasks_loader_zip.output_sha256
}

data "archive_file" "tasks_loader_zip" {

  type        = "zip"
  source_dir  = "${path.module}/tasks_loader"
  output_path = "${path.module}/tasks_loader.zip"
}


