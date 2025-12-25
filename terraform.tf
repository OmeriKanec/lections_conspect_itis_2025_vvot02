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
  cloud_id                  = var.cloud_id
  folder_id                 = var.folder_id
}

# Создание сервисного аккаунта и назначение ему ролей
# Сервисный аккаунт
resource "yandex_iam_service_account" "lection_sa" {
  name        = "tg-video-bot-sa"
  description = "Service account for Telegram video bot (Cloud Functions, MQ, Object Storage)"
}

# storage.editor — доступ к Object Storage
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_storage" {
  folder_id = var.folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

# ymq.reader — чтение сообщений из очередей
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_ymq_reader" {
  folder_id = var.folder_id
  role      = "ymq.reader"
  member    = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

# ymq.writer — запись сообщений в очереди
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_ymq_writer" {
  folder_id = var.folder_id
  role      = "ymq.writer"
  member    = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

# functions.invoker — право вызывать функции
resource "yandex_resourcemanager_folder_iam_member" "lection_sa_functions_invoker" {
  folder_id = var.folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.lection_sa.id}"
  depends_on = [yandex_iam_service_account.lection_sa]
}

# Ключ доступа
resource "yandex_iam_service_account_static_access_key" "sa_static_key" {
  service_account_id = yandex_iam_service_account.lection_sa.id
  description        = "Access key for vvot02"
  depends_on = [yandex_resourcemanager_folder_iam_member.lection_sa_storage]
}



resource "yandex_iam_service_account" "ymq_admin" {
  name = "vvot02-ymq-admin"
}

resource "yandex_resourcemanager_folder_iam_member" "ymq_admin_role" {
  folder_id = var.folder_id
  role      = "ymq.admin"
  member    = "serviceAccount:${yandex_iam_service_account.ymq_admin.id}"
  depends_on = [yandex_iam_service_account.ymq_admin]
}

resource "yandex_iam_service_account_static_access_key" "ymq_admin" {
  service_account_id = yandex_iam_service_account.ymq_admin.id
  depends_on = [yandex_resourcemanager_folder_iam_member.ymq_admin_role]
}

locals {
  ymq_admin_access_key = yandex_iam_service_account_static_access_key.ymq_admin.access_key
  ymq_admin_secret_key = yandex_iam_service_account_static_access_key.ymq_admin.secret_key
}



resource "time_sleep" "iam_replication" {
  depends_on = [yandex_iam_service_account.ymq_admin, yandex_iam_service_account.lection_sa]
  create_duration = "12s"
}




# Бакет
resource "yandex_storage_bucket" "lection" {
  bucket = "vvot02-tg-video"
  folder_id = var.folder_id
  force_destroy = true
  depends_on = [yandex_iam_service_account.lection_sa]
}




# Создание и настройка Api Gateway
resource "yandex_api_gateway" "vvot02_api_gw" {
  name        = "vvot02-api-gw"
  description = "Telegram video bot webhook API Gateway"
  execution_timeout = "30"
  spec              = templatefile("${path.module}/api_gateway.yaml", {
#    QUEUE_RECEIVER_URL = yandex_message_queue.receiver.id
#    FOLDER_ID          = var.folder_id
    SA_ID              = yandex_iam_service_account.lection_sa.id
    FORM_LOADER_FUNCTION_ID = yandex_function.form_loader.id
    FORM_PROCESSOR_FUNCTION_ID = yandex_function.form_processor.id
#    VIDEO_BUCKET       = yandex_storage_bucket.video_bucket.bucket
  })

}

output "api_gateway_url" {
  value       = "https://${yandex_api_gateway.vvot02_api_gw.domain}"
  description = "API Gateway URL"
}



# Функция загрузки видео, отправки его в бакет и отправки ссылки пользавотелю
resource "yandex_function" "form_loader" {
  name        = "vvot02-form-loader"
  folder_id   = var.folder_id
  description = "Receives Video, downloads it, sends it to bucket"

  entrypoint  = "main.handler"
  runtime     = "python39"
  memory      = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout = "30"
  environment = {
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

# Функция загрузки видео, отправки его в бакет и отправки ссылки пользавотелю
resource "yandex_function" "form_processor" {
  name        = "vvot02-form-processor"
  folder_id   = var.folder_id
  description = "Receives Video, downloads it, sends it to bucket"

  entrypoint  = "main.handler"
  runtime     = "python39"
  memory      = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout = "30"
  environment = {
    REGION_NAME = var.region
    DOWNLOADER_QUEUE_URL = yandex_message_queue.downloader_queue.id
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
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



# Очередь для приёма сообщений от Telegram webhook (через API Gateway)
#resource "yandex_message_queue" "receiver_queue" {
#  name               = "vvot02-queue-receiver"
#  visibility_timeout_seconds = 600
#  message_retention_seconds  = 604800
#  receive_wait_time_seconds  = 20
#  access_key                  = local.ymq_admin_access_key
#  secret_key                  = local.ymq_admin_secret_key
#  depends_on = [yandex_iam_service_account.ymq_admin,
#  time_sleep.iam_replication]
#}
#
## Триггер для func_receiver (очередь → функция)
#resource "yandex_function_trigger" "receiver_trigger" {
#  name        = "vvot02-trigger-receiver"
#  function {
#    id                 = yandex_function.receiver.id
#    service_account_id = yandex_iam_service_account.lection_sa.id
#  }
#
#  message_queue {
#    queue_id = yandex_message_queue.receiver_queue.arn
#    service_account_id = yandex_iam_service_account.lection_sa.id
#    batch_size = "1"
#    batch_cutoff = "10"
#  }
#
#  depends_on = [
#    yandex_function.receiver,
#    yandex_message_queue.receiver_queue
#  ]
#
#}
#
## Облачная функция приёмник сообщений от Telegram
#resource "yandex_function" "receiver" {
#  name        = "vvot02-func-receiver"
#  folder_id   = var.folder_id
#  description = "Receives Telegram updates, checks video, sends to downloader queue"
#
#  entrypoint  = "main.handler"
#  runtime     = "python39"
#  memory      = 512
#  service_account_id = yandex_iam_service_account.lection_sa.id
#  execution_timeout = "30"
#  environment = {
#    DOWNLOADER_QUEUE_URL   = yandex_message_queue.downloader_queue.id
#    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
#    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
#    REGION_NAME = var.region
#  }
#
#  content {
#    zip_filename = data.archive_file.func_receiver_zip.output_path
#  }
#  user_hash = data.archive_file.func_receiver_zip.output_sha256
#}
#
#data "archive_file" "func_receiver_zip" {
#
#  type        = "zip"
#  source_dir  = "${path.module}/func_receiver"
#  output_path = "${path.module}/func_receiver.zip"
#}
#
# Очередь на загрузку видео
resource "yandex_message_queue" "downloader_queue" {
  name               = "vvot02-queue-downloader"
  visibility_timeout_seconds = "1200"
  message_retention_seconds  = "604800"
  receive_wait_time_seconds  = "20"
  access_key                  = local.ymq_admin_access_key
  secret_key                  = local.ymq_admin_secret_key
  depends_on = [yandex_iam_service_account.ymq_admin,
  time_sleep.iam_replication]
}

# Функция загрузки видео, отправки его в бакет и отправки ссылки пользавотелю
resource "yandex_function" "downloader" {
  name        = "vvot02-func-downloader"
  folder_id   = var.folder_id
  description = "Receives Video, downloads it, sends it to bucket"

  entrypoint  = "main.handler"
  runtime     = "python39"
  memory      = 512
  service_account_id = yandex_iam_service_account.lection_sa.id
  execution_timeout = "30"
  environment = {
    AWS_ACCESS_KEY_ID     = yandex_iam_service_account_static_access_key.sa_static_key.access_key
    AWS_SECRET_ACCESS_KEY = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
    STORAGE_BUCKET      = yandex_storage_bucket.lection.bucket
    REGION_NAME = var.region
  }

  content {
    zip_filename = data.archive_file.video_downloader_zip.output_path
  }
  user_hash = data.archive_file.video_downloader_zip.output_sha256
}

data "archive_file" "video_downloader_zip" {

  type        = "zip"
  source_dir  = "${path.module}/video_downloader"
  output_path = "${path.module}/video_downloader.zip"
}

resource "yandex_function_trigger" "downloader_trigger" {
  name        = "vvot02-trigger-downloader"
  function {
    id                 = yandex_function.downloader.id
    service_account_id = yandex_iam_service_account.lection_sa.id
  }

  message_queue {
    queue_id = yandex_message_queue.downloader_queue.arn
    service_account_id = yandex_iam_service_account.lection_sa.id
    batch_size = "1"
    batch_cutoff = "10"
  }

  depends_on = [
    yandex_function.downloader,
    yandex_message_queue.downloader_queue
  ]

}






