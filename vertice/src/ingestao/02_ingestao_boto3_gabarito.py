# Databricks notebook source
# /// script
# [tool.databricks.environment]
# environment_version = "6"
# ///
# MAGIC %md
# MAGIC # Noite 2 · 2 de 2 · Ingestão do data lake com boto3 · gabarito

# COMMAND ----------

# MAGIC %md
# MAGIC Um notebook novo, `02_ingestao_boto3`, serverless. Com lacunas para fazer junto:
# MAGIC [`02_ingestao_boto3.py`](02_ingestao_boto3.py) · código pronto: [`02_ingestao_boto3_gabarito.py`](02_ingestao_boto3_gabarito.py). O mesmo extrair-pousar-carregar da API, agora
# MAGIC para o data lake inteiro. As 4 caixinhas do topo recebem os valores da tabela de conexão.
# MAGIC
# MAGIC Ontem você baixou os arquivos e subiu no volume **na mão**. Numa empresa, os sistemas e as
# MAGIC ferramentas exportam tudo para um **data lake**: um storage na nuvem que fala o protocolo **S3** da AWS.
# MAGIC Aqui o data lake é o Storage do Supabase, e o código é exatamente o que você usaria na Amazon:
# MAGIC muda só o `endpoint_url`.
# MAGIC
# MAGIC Os três passos de toda ingestão:
# MAGIC 1. **extrair** · o `boto3` lista e baixa cada arquivo do bucket `DataLakeCentralTower`
# MAGIC 2. **pousar** · cada arquivo vai para o volume, no mesmo caminho: `/Volumes/lakehouse_vertice/bronze/raw/`
# MAGIC 3. **carregar** · o mesmo `read_files` de ontem transforma o raw nas 9 tabelas da bronze
# MAGIC
# MAGIC Rode com a computação **serverless**, uma célula de cada vez.
# MAGIC
# MAGIC ## Configuração: as chaves chegam pelo ambiente
# MAGIC
# MAGIC A chave **não fica escrita no código**. O notebook lê tudo de `os.environ`, as variáveis de ambiente,
# MAGIC como em qualquer servidor ou na própria AWS. Quem preenche os valores é o **job**: cada parâmetro do job
# MAGIC chega ao notebook como um *widget* com o mesmo nome, e a célula abaixo passa os widgets para o ambiente.
# MAGIC
# MAGIC - **Rodando na mão:** aparecem 4 caixinhas no topo do notebook. Cole os valores da tabela de conexão.
# MAGIC - **Rodando pelo job:** os valores vêm dos **Parameters** da tarefa (etapa 4). Ninguém digita nada.
# MAGIC - **Ou pelo campo Environment variables (Beta)** da tarefa: aí os valores já chegam no `os.environ`, e a
# MAGIC   célula usa direto, sem caixinha.
# MAGIC
# MAGIC Os nomes `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` são o padrão da AWS: o `boto3` encontra as chaves
# MAGIC sozinho no ambiente, sem você passar no código.

# COMMAND ----------

#dbutils.widgets.text("S3_ENDPOINT", "")
#dbutils.widgets.text("AWS_DEFAULT_REGION", "")
#dbutils.widgets.text("AWS_ACCESS_KEY_ID", "")
#dbutils.widgets.text("AWS_SECRET_ACCESS_KEY", "")

# COMMAND ----------

import os

VARIAVEIS = ["S3_ENDPOINT","AWS_DEFAULT_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]

for nome in VARIAVEIS:
    if os.environ.get(nome):                       # já veio do job (Environment variables)? usa esse
        continue
    dbutils.widgets.text(nome, "")                 # senão, a caixinha (o job preenche pelos Parameters)
    os.environ[nome] = dbutils.widgets.get(nome)   # e o valor vira variável de ambiente

faltando = [nome for nome in VARIAVEIS if not os.environ[nome]]
assert not faltando, f"preencha: {faltando}"      # para aqui se faltar alguma chave

S3_BUCKET = "DataLakeVertice"
RAW = "/Volumes/lakehouse_vertice/bronze/raw"
print("ambiente pronto:", os.environ["S3_ENDPOINT"])

# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 1 · Conectar no data lake
# MAGIC
# MAGIC Repare: nenhuma chave no código. O `boto3` lê `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e
# MAGIC `AWS_DEFAULT_REGION` do ambiente; só o endereço do Supabase vai explícito.

# COMMAND ----------

import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["S3_ENDPOINT"],
    config=Config(s3={"addressing_style": "path"}),   # o Supabase só entende o bucket no caminho da URL
)

for bucket in s3.list_buckets()["Buckets"]:
    print(bucket["Name"])

# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 2 · O que tem no bucket?
# MAGIC
# MAGIC Cada arquivo é um objeto com uma **Key** (o caminho) e um **Size**. O S3 devolve no máximo 1.000
# MAGIC por página; o *paginator* busca todas as páginas.

# COMMAND ----------

objetos = []
for pagina in s3.get_paginator("list_objects_v2").paginate(Bucket=S3_BUCKET):
    objetos += pagina.get("Contents", [])

# só arquivos (o storage cria um objeto vazio de marcação em cada pasta)
arquivos = [o["Key"] for o in objetos if not o["Key"].endswith("/") and o["Size"] > 0
            and not o["Key"].endswith(".emptyFolderPlaceholder")]

from collections import Counter
for pasta, n in sorted(Counter(k.split("/")[0] for k in arquivos).items()):
    print(f"{pasta:<12} {n:>3} arquivos")
print(f"{'total':<12} {len(arquivos):>3}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 3 · Apague o trabalho manual de ontem
# MAGIC
# MAGIC É proposital: as pastas do raw e as 9 tabelas da bronze somem, e voltam vindas do data lake.

# COMMAND ----------

TABELAS = ["projetos", "status_semanal", "excel_tarefas", "clickup_tarefas", "msproject_tarefas",
           "colaboradores", "apontamentos", "custos", "entregas_fornecedor"]

for tabela in TABELAS:
    spark.sql(f"DROP TABLE IF EXISTS lakehouse_vertice.bronze.{tabela}")

for pasta in sorted({k.split("/")[0] for k in arquivos}):
    dbutils.fs.rm(f"{RAW}/{pasta}", True)
    print("apagada:", f"{RAW}/{pasta}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 4 · Extrair e pousar: cada arquivo do bucket vai para o raw

# COMMAND ----------

import os

def baixar(key):
    destino = f"{RAW}/{key}"                                   # o mesmo caminho do bucket
    os.makedirs(os.path.dirname(destino), exist_ok=True)
    conteudo = s3.get_object(Bucket=S3_BUCKET, Key=key)["Body"].read()   # 1 · extrair
    with open(destino, "wb") as f:                                        # 2 · pousar
        f.write(conteudo)
    return len(conteudo)

total = 0
for key in arquivos:
    total += baixar(key)
print(f"{len(arquivos)} arquivos, {total/1e6:.1f} MB no raw")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Passo 5 · Carregar: o raw vira a bronze, com o mesmo SQL de ontem
# MAGIC
# MAGIC Tudo como texto, sem limpar nada: a bronze guarda o que chegou. A limpeza é amanhã, na silver.

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.projetos AS
# MAGIC SELECT * EXCEPT (_rescued_data)
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/pmo/projetos.csv',
# MAGIC                 format => 'csv', header => true, inferColumnTypes => false);
# MAGIC
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.status_semanal AS
# MAGIC SELECT * EXCEPT (_rescued_data)
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/pmo/status_semanal.csv',
# MAGIC                 format => 'csv', header => true, inferColumnTypes => false);
# MAGIC
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.colaboradores AS
# MAGIC SELECT * EXCEPT (_rescued_data)
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/rh/colaboradores.csv',
# MAGIC                 format => 'csv', header => true, inferColumnTypes => false);
# MAGIC
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.apontamentos AS
# MAGIC SELECT * EXCEPT (_rescued_data)
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/timesheet/apontamentos.csv',
# MAGIC                 format => 'csv', header => true, inferColumnTypes => false);
# MAGIC
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.custos AS
# MAGIC SELECT * EXCEPT (_rescued_data)
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/financeiro/custos.csv',
# MAGIC                 format => 'csv', header => true, inferColumnTypes => false);
# MAGIC
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.entregas_fornecedor AS
# MAGIC SELECT * EXCEPT (_rescued_data)
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/compras/entregas_fornecedor.csv',
# MAGIC                 format => 'csv', header => true, inferColumnTypes => false);

# COMMAND ----------

# MAGIC %sql
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.excel_tarefas AS
# MAGIC SELECT `ID`               AS id,
# MAGIC        `Fase`             AS fase,
# MAGIC        `Tarefa`           AS tarefa,
# MAGIC        `Responsável`      AS responsavel,
# MAGIC        `Início previsto`  AS inicio_previsto,
# MAGIC        `Término previsto` AS termino_previsto,
# MAGIC        `Início real`      AS inicio_real,
# MAGIC        `Término real`     AS termino_real,
# MAGIC        `% Concluído`      AS pct_concluido,
# MAGIC        `Horas previstas`  AS horas_previstas,
# MAGIC        url_decode(_metadata.file_name) AS arquivo
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/excel/',
# MAGIC                 format => 'excel', headerRows => 1, inferColumnTypes => false);
# MAGIC
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.clickup_tarefas AS
# MAGIC SELECT list.id   AS list_id,
# MAGIC        list.name AS list_name,
# MAGIC        t.*,
# MAGIC        url_decode(_metadata.file_name) AS arquivo
# MAGIC FROM (
# MAGIC     SELECT list, explode(tasks) AS t, _metadata
# MAGIC     FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/clickup/',
# MAGIC                     format => 'json', multiLine => true)
# MAGIC );
# MAGIC
# MAGIC CREATE OR REPLACE TABLE lakehouse_vertice.bronze.msproject_tarefas AS
# MAGIC SELECT * EXCEPT (_rescued_data),
# MAGIC        url_decode(_metadata.file_name) AS arquivo
# MAGIC FROM read_files('/Volumes/lakehouse_vertice/bronze/raw/msproject/',
# MAGIC                 format => 'xml', rowTag => 'Task');

# COMMAND ----------

# MAGIC %sql
# MAGIC -- Deve aparecer o mesmo de ontem:
# MAGIC -- apontamentos 30.883 · custos 23.640 · status_semanal 3.911 · clickup_tarefas 2.119 · excel_tarefas 1.663
# MAGIC -- msproject_tarefas 1.260 · entregas_fornecedor 640 · colaboradores 523 · projetos 60
# MAGIC SELECT 'projetos' AS tabela, COUNT(*) AS linhas FROM lakehouse_vertice.bronze.projetos
# MAGIC UNION ALL SELECT 'status_semanal', COUNT(*) FROM lakehouse_vertice.bronze.status_semanal
# MAGIC UNION ALL SELECT 'excel_tarefas', COUNT(*) FROM lakehouse_vertice.bronze.excel_tarefas
# MAGIC UNION ALL SELECT 'clickup_tarefas', COUNT(*) FROM lakehouse_vertice.bronze.clickup_tarefas
# MAGIC UNION ALL SELECT 'msproject_tarefas', COUNT(*) FROM lakehouse_vertice.bronze.msproject_tarefas
# MAGIC UNION ALL SELECT 'colaboradores', COUNT(*) FROM lakehouse_vertice.bronze.colaboradores
# MAGIC UNION ALL SELECT 'apontamentos', COUNT(*) FROM lakehouse_vertice.bronze.apontamentos
# MAGIC UNION ALL SELECT 'custos', COUNT(*) FROM lakehouse_vertice.bronze.custos
# MAGIC UNION ALL SELECT 'entregas_fornecedor', COUNT(*) FROM lakehouse_vertice.bronze.entregas_fornecedor
# MAGIC ORDER BY linhas DESC