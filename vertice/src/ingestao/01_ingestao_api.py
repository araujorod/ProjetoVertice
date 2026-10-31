# Databricks notebook source
# /// script
# [tool.databricks.environment]
# environment_version = "6"
# ///
# MAGIC %md
# MAGIC # Noite 2 · 1 de 2 · Ingestão de uma API

# COMMAND ----------

# MAGIC %md
# MAGIC A primeira ingestão da noite, e a mais simples: uma API pública, sem chave. Na empresa, o dado não chega
# MAGIC pronto: alguém precisa ir buscar. Quando a fonte não tem conector, entra o Python, sempre em três passos:
# MAGIC **extrair** (pedir à API), **pousar** (guardar o arquivo no raw, do jeito que veio) e **carregar** (o
# MAGIC `read_files` transforma o arquivo em tabela).
# MAGIC
# MAGIC **Pergunta de negócio:** quantos dias úteis a Vértice perde em novembro, bem quando começa o change freeze
# MAGIC da Black Friday (01/11)?
# MAGIC
# MAGIC No Databricks: **New › Notebook**, nome `01_ingestao_api`, computação **serverless** (ela tem internet).
# MAGIC Cole uma célula de cada vez. Com lacunas para fazer junto: [`01_ingestao_api.py`](01_ingestao_api.py) · código pronto:
# MAGIC [`01_ingestao_api_gabarito.py`](01_ingestao_api_gabarito.py).
# MAGIC
# MAGIC ## Passo 1 · Extrair: pedir os feriados à API

# COMMAND ----------

import requests                # conversa com a API (HTTP)

url = "https://brasilapi.com.br/api/feriados/v1/2026"

# Objetivo: pedir os feriados à API e transformar a resposta em lista do Python.

# 1. 
resposta = requests.get(url, timeout=30)

# 2. 
resposta.raise_for_status()      #-> se a API cair, para aqui


# 3. 
feriados = resposta.json()


# 4. imprima quantos feriados vieram (len) e mostre os 3 primeiros (feriados[:3])
print(len(feriados))
print(feriados[:3])

# escreva seu código aqui

# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 2 · Pousar: o JSON numa pasta nova do raw
# MAGIC
# MAGIC Cada execução grava um arquivo **novo**, com a data e a hora no nome. O raw guarda o histórico de
# MAGIC tudo o que chegou: dá para saber o que a API respondia em cada momento.

# COMMAND ----------

import json, os
from datetime import datetime

pasta = "/Volumes/lakehouse_vertice/bronze/raw/feriados"
os.makedirs(pasta, exist_ok=True)                        # a pasta nova precisa existir

agora = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")     # ex.: 2026-10-20_19-40-00 (horário UTC)

# Objetivo: gravar a lista `feriados` no arquivo 
# 
arquivo = f"{pasta}/feriados_{agora}.json"
with open(arquivo, "w") as arquivo:
    json.dump(feriados, arquivo, ensure_ascii=False)

# Depois, liste a pasta com sorted(os.listdir(pasta)).

sorted(os.listdir(pasta))

# escreva seu código aqui

# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 3 · Carregar: o raw vira a bronze
# MAGIC
# MAGIC O mesmo `read_files` da noite 1, lendo **todos** os arquivos da pasta. Duas colunas a mais contam de onde
# MAGIC e de quando veio cada linha.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.feriados
# MAGIC COMMENT 'Feriados nacionais de 2026, da BrasilAPI. Uma captura por execução do job.'
# MAGIC AS SELECT date AS data, name AS feriado, type AS tipo, weekday AS dia_da_semana,
# MAGIC           _metadata.file_name              AS arquivo,
# MAGIC           _metadata.file_modification_time AS coletado_em
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/feriados/', format => 'json', multiLine => true)

# COMMAND ----------



# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 4 · Conferir

# COMMAND ----------

# MAGIC %sql
# MAGIC -- uma linha por captura: 14 feriados em cada uma
# MAGIC SELECT arquivo, coletado_em, COUNT(*) AS feriados
# MAGIC FROM lakehouse_vertice.bronze.feriados
# MAGIC GROUP BY arquivo, coletado_em
# MAGIC ORDER BY coletado_em DESC

# COMMAND ----------

# MAGIC %sql
# MAGIC -- a resposta para o negócio, na captura mais recente:
# MAGIC -- 02/11 (segunda), 15/11 (domingo) e 20/11 (sexta): 2 dias úteis a menos em novembro
# MAGIC SELECT data, feriado, dia_da_semana
# MAGIC FROM lakehouse_vertice.bronze.feriados
# MAGIC WHERE arquivo = (SELECT MAX(arquivo) FROM lakehouse_vertice.bronze.feriados)
# MAGIC   AND data BETWEEN '2026-11-01' AND '2026-11-30'
# MAGIC ORDER BY data