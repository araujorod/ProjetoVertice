#!/usr/bin/env python3
"""Gera resources/dashboard-portfolio.lvdash.json, o dashboard AI/BI do Projeto Farol.

O dashboard é código: este script monta o JSON (datasets + 3 páginas) e o bundle
publica pelo recurso resources/dashboard.dashboard.yml.

Regras do JSON (skill databricks-aibi-dashboards):
  - tabelas da gold com o nome PURO (o catálogo e o schema vêm do recurso:
    dataset_catalog e dataset_schema). A silver vai com o nome completo.
  - versões: counter 2, table 2, bar/line/scatter 3. Toda página com GRID_V1.
  - cada linha da grade soma 12 de largura.
  - razão é SUM/SUM no SQL, nunca AVG de razão.

Uso:
  python3 scripts/gerar_dashboard.py
"""
import json
from pathlib import Path

SAIDA = Path(__file__).resolve().parent.parent / "resources" / "dashboard-portfolio.lvdash.json"

# cores da Jornada e as cores da situação
AZUL, CIANO, FUNDO_ESCURO = "#0059DB", "#22C2F4", "#14141A"
CRITICO, ATENCAO, OK = "#FF5F46", "#F6C344", "#22C2F4"

REAIS = {"type": "number-currency", "currencyCode": "BRL", "abbreviation": "compact",
         "decimalPlaces": {"type": "max", "places": 2}}
INDICE = {"type": "number-plain", "decimalPlaces": {"type": "exact", "places": 2}}
PERCENTUAL = {"type": "number-percent", "decimalPlaces": {"type": "max", "places": 1}}
CORES_SITUACAO = {"type": "categorical", "mappings": [
    {"value": "crítico", "color": CRITICO},
    {"value": "atenção", "color": ATENCAO},
    {"value": "ok", "color": OK},
]}


# =============================================================================
# Datasets: uma query por assunto
# =============================================================================
DATASETS = {
    # 1 linha: os KPIs da carteira em andamento
    "ds_carteira": ("Carteira em andamento", """
SELECT
  sum(valor_contrato)                         AS carteira,
  sum(ev) / sum(pv)                           AS spi,
  sum(ev) / sum(ac)                           AS cpi,
  sum(estouro_previsto)                       AS estouro_previsto,
  count_if(situacao IN ('crítico', 'atenção')) AS em_risco,
  count_if(situacao = 'crítico')              AS criticos,
  count_if(melancia)                          AS melancias
FROM projeto_situacao_atual
WHERE status = 'em_andamento'
"""),

    # 1 linha por projeto em andamento: barra, dispersão e tabela
    "ds_projetos": ("Projetos em andamento", """
SELECT
  projeto,
  cliente,
  segmento,
  gerente_projeto,
  situacao,
  spi,
  cpi,
  estouro_previsto,
  margem_projetada,
  atraso_projetado_dias,
  farol_do_gerente,
  farol_calculado,
  CASE WHEN melancia THEN 'sim' ELSE '' END AS melancia
FROM projeto_situacao_atual
WHERE status = 'em_andamento'
ORDER BY estouro_previsto DESC
"""),

    # SPI e CPI da carteira, sexta a sexta
    "ds_semanal": ("SPI e CPI semanais", """
SELECT
  semana,
  sum(ev) / sum(pv) AS spi,
  sum(ev) / sum(ac) AS cpi
FROM fato_projeto_semana
WHERE semana >= DATE'2025-03-07'
GROUP BY semana
ORDER BY semana
"""),

    # top 15 pessoas por custo da hora parada (últimas 12 semanas)
    "ds_top_parados": ("Top 15 custo da hora parada", """
SELECT
  concat(colaborador_id, ' · ', nome, ' (', papel, ')') AS pessoa,
  sum(custo_ocioso)                                    AS custo_ocioso,
  sum(horas_apontadas) / sum(horas_disponiveis)        AS utilizacao
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24'
GROUP BY colaborador_id, nome, papel
ORDER BY custo_ocioso DESC
LIMIT 15
"""),

    # utilização por pessoa e projeto (últimas 12 semanas)
    "ds_utilizacao": ("Utilização por pessoa e projeto", """
SELECT
  colaborador_id,
  nome,
  papel,
  senioridade,
  projeto_id,
  sum(horas_disponiveis)                        AS horas_disponiveis,
  sum(horas_apontadas)                          AS horas_apontadas,
  sum(horas_apontadas) / sum(horas_disponiveis) AS utilizacao,
  sum(custo_ocioso)                             AS custo_ocioso
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24'
GROUP BY colaborador_id, nome, papel, senioridade, projeto_id
ORDER BY utilizacao ASC
"""),

    # causas de bloqueio por projeto (últimos 90 dias)
    "ds_causas": ("Causas de bloqueio (90 dias)", """
SELECT
  projeto_id,
  causa_bloqueio,
  count(*)          AS semanas,
  sum(dias_impacto) AS dias_impacto
FROM status_estruturado
WHERE data_status >= DATE'2026-07-18'
  AND causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
GROUP BY projeto_id, causa_bloqueio
ORDER BY projeto_id
"""),

    # fornecedores: a silver vai com o nome completo
    "ds_fornecedores": ("Fornecedores", """
SELECT
  fornecedor,
  count(DISTINCT fornecedor_como_veio)                                  AS grafias_no_cadastro,
  count(*)                                                              AS entregas,
  try_divide(sum(prazo_real_dias), sum(CASE WHEN NOT em_aberto THEN prazo_prometido_dias END))
                                                                        AS prazo_real_sobre_prometido,
  try_divide(count_if(data_entrega <= data_prometida), count_if(NOT em_aberto))
                                                                        AS pct_no_prazo,
  count_if(em_atraso)                                                   AS em_atraso_hoje
FROM lakehouse_vertice.silver.entregas_fornecedor
GROUP BY fornecedor
ORDER BY em_atraso_hoje DESC, prazo_real_sobre_prometido DESC
"""),

    "ds_atrasadas": ("Entregas em atraso hoje", """
SELECT
  entrega_id,
  fornecedor,
  projeto_id,
  item,
  valor,
  data_pedido,
  data_prometida,
  datediff(DATE'2026-10-16', data_prometida) AS dias_de_atraso
FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE em_atraso
ORDER BY dias_de_atraso DESC
"""),
}


def dataset(nome, titulo, sql):
    linhas = [l + "\n" for l in sql.strip().splitlines()]
    return {"name": nome, "displayName": titulo, "queryLines": linhas}


# =============================================================================
# Widgets: uma função por tipo, para não repetir o boilerplate
# =============================================================================
def pos(x, y, w, h):
    return {"x": x, "y": y, "width": w, "height": h}


def texto(nome, md, p):
    return {"widget": {"name": nome, "multilineTextboxSpec": {"lines": [md]}}, "position": p}


def query(ds, colunas, filtros=None):
    q = {"datasetName": ds, "fields": [{"name": c, "expression": f"`{c}`"} for c in colunas],
         "disaggregated": True}
    if filtros:
        q["filters"] = [{"expression": f} for f in filtros]
    return [{"name": "main_query", "query": q}]


def frame(titulo, descricao=None):
    f = {"showTitle": True, "title": titulo}
    if descricao:
        f.update(description=descricao, showDescription=True)
    return f


def contador(nome, coluna, titulo, p, fmt=None, descricao=None):
    valor = {"fieldName": coluna, "displayName": titulo}
    if fmt:
        valor["format"] = fmt
    return {"widget": {"name": nome, "queries": query("ds_carteira", [coluna]),
                       "spec": {"version": 2, "widgetType": "counter",
                                "encodings": {"value": valor},
                                "frame": frame(titulo, descricao)}},
            "position": p}


def tabela(nome, ds, colunas, titulo, p, descricao=None):
    """colunas: lista de (campo, rótulo, formato ou None)"""
    cols = []
    for campo, rotulo, fmt in colunas:
        c = {"fieldName": campo, "displayName": rotulo}
        if fmt:
            c["format"] = fmt
        cols.append(c)
    return {"widget": {"name": nome, "queries": query(ds, [c[0] for c in colunas]),
                       "spec": {"version": 2, "widgetType": "table",
                                "encodings": {"columns": cols},
                                "frame": frame(titulo, descricao)}},
            "position": p}


def grafico(nome, tipo, ds, campos, encodings, titulo, p, descricao=None, filtros=None):
    return {"widget": {"name": nome, "queries": query(ds, campos, filtros),
                       "spec": {"version": 3, "widgetType": tipo, "encodings": encodings,
                                "frame": frame(titulo, descricao)}},
            "position": p}


def pagina(nome, titulo, layout):
    return {"name": nome, "displayName": titulo, "pageType": "PAGE_TYPE_CANVAS",
            "layoutVersion": "GRID_V1", "layout": layout}


# =============================================================================
# Página 1 · Portfólio (perguntas 1 e 2)
# =============================================================================
portfolio = pagina("portfolio", "Portfólio", [
    texto("titulo_portfolio",
          "## Quais projetos estão atrasados, de quais clientes, e quanto isso vai me custar?",
          pos(0, 0, 12, 1)),
    texto("subtitulo_portfolio",
          "Carteira em andamento em 16/10/2026. Atenção: SPI ou CPI < 0,9 · crítico: < 0,8. "
          "Melancia: farol do gerente verde com SPI < 0,9.",
          pos(0, 1, 12, 1)),
    # linha 1 de KPIs (4 × 3)
    contador("kpi_carteira", "carteira", "Carteira (contratos)", pos(0, 2, 3, 3), REAIS),
    contador("kpi_spi", "spi", "SPI da carteira", pos(3, 2, 3, 3), INDICE, "Σ EV ÷ Σ PV · < 1 é atraso"),
    contador("kpi_cpi", "cpi", "CPI da carteira", pos(6, 2, 3, 3), INDICE, "Σ EV ÷ Σ AC · < 1 é estouro"),
    contador("kpi_estouro", "estouro_previsto", "Estouro previsto", pos(9, 2, 3, 3), REAIS,
             "Σ (EAC − orçamento), só quando positivo"),
    # linha 2 de KPIs (3 × 4)
    contador("kpi_em_risco", "em_risco", "Projetos em risco", pos(0, 5, 4, 3), None, "atenção + crítico"),
    contador("kpi_criticos", "criticos", "Críticos", pos(4, 5, 4, 3), None, "SPI ou CPI < 0,8"),
    contador("kpi_melancias", "melancias", "Melancias", pos(8, 5, 4, 3), None,
             "verde por fora (farol do gerente), vermelho por dentro (SPI)"),
    # estouro por projeto + dispersão
    grafico("estouro_por_projeto", "bar", "ds_projetos",
            ["projeto", "estouro_previsto", "situacao"],
            {"x": {"fieldName": "estouro_previsto", "displayName": "Estouro previsto",
                   "scale": {"type": "quantitative"}, "format": REAIS},
             "y": {"fieldName": "projeto", "displayName": "Projeto",
                   "scale": {"type": "categorical", "sort": {"by": "x-reversed"}}},
             "color": {"fieldName": "situacao", "displayName": "Situação", "scale": CORES_SITUACAO}},
            "Estouro previsto por projeto", pos(0, 8, 6, 7),
            "Só os projetos com estouro previsto", ["`estouro_previsto` > 0"]),
    grafico("spi_x_cpi", "scatter", "ds_projetos",
            ["spi", "cpi", "situacao", "projeto"],
            {"x": {"fieldName": "spi", "displayName": "SPI (prazo)", "scale": {"type": "quantitative"}},
             "y": {"fieldName": "cpi", "displayName": "CPI (custo)", "scale": {"type": "quantitative"}},
             "color": {"fieldName": "situacao", "displayName": "Situação", "scale": CORES_SITUACAO}},
            "SPI × CPI · um ponto por projeto", pos(6, 8, 6, 7),
            "Embaixo e à esquerda de 0,9: atrasado e estourando"),
    # evolução semanal
    grafico("spi_cpi_semanal", "line", "ds_semanal", ["semana", "spi", "cpi"],
            {"x": {"fieldName": "semana", "displayName": "Semana", "scale": {"type": "temporal"}},
             "y": {"scale": {"type": "quantitative"}, "format": INDICE,
                   "fields": [{"fieldName": "spi", "displayName": "SPI"},
                              {"fieldName": "cpi", "displayName": "CPI"}]}},
            "SPI e CPI da carteira, semana a semana", pos(0, 15, 12, 6),
            "Σ EV ÷ Σ PV e Σ EV ÷ Σ AC de todos os projetos ativos em cada sexta"),
    # a tabela
    tabela("tabela_projetos", "ds_projetos", [
        ("projeto", "Projeto", None),
        ("cliente", "Cliente", None),
        ("gerente_projeto", "Gerente", None),
        ("situacao", "Situação", None),
        ("spi", "SPI", INDICE),
        ("cpi", "CPI", INDICE),
        ("farol_do_gerente", "Farol do gerente", None),
        ("farol_calculado", "Farol pelo número", None),
        ("melancia", "Melancia", None),
        ("estouro_previsto", "Estouro previsto", REAIS),
        ("margem_projetada", "Margem projetada", PERCENTUAL),
        ("atraso_projetado_dias", "Atraso projetado (dias)", None),
    ], "Projetos em andamento: o farol do gerente ao lado do farol pelo número", pos(0, 21, 12, 9)),
])

# =============================================================================
# Página 2 · Pessoas (pergunta 3)
# =============================================================================
pessoas = pagina("pessoas", "Pessoas", [
    texto("titulo_pessoas",
          "## Tenho gente parada enquanto outro projeto pede gente?",
          pos(0, 0, 12, 1)),
    texto("subtitulo_pessoas",
          "Timesheet das últimas 12 semanas (31/07 a 16/10/2026) e as causas declaradas no status dos últimos 90 dias.",
          pos(0, 1, 12, 1)),
    grafico("top_parados", "bar", "ds_top_parados", ["pessoa", "custo_ocioso"],
            {"x": {"fieldName": "custo_ocioso", "displayName": "Custo da hora parada",
                   "scale": {"type": "quantitative"}, "format": REAIS},
             "y": {"fieldName": "pessoa", "displayName": "Pessoa",
                   "scale": {"type": "categorical", "sort": {"by": "x-reversed"}}}},
            "Top 15 · custo da hora parada", pos(0, 2, 6, 8),
            "horas disponíveis − apontadas, × custo por hora"),
    grafico("causas_por_projeto", "bar", "ds_causas", ["projeto_id", "semanas", "causa_bloqueio"],
            {"x": {"fieldName": "projeto_id", "displayName": "Projeto", "scale": {"type": "categorical"}},
             "y": {"fieldName": "semanas", "displayName": "Semanas com o bloqueio",
                   "scale": {"type": "quantitative"}},
             "color": {"fieldName": "causa_bloqueio", "displayName": "Causa", "scale": {"type": "categorical"}}},
            "Causas de bloqueio por projeto · últimos 90 dias", pos(6, 2, 6, 8),
            "gold.status_estruturado (IA), sem 'sem_bloqueio' e 'nao_reportado'"),
    tabela("tabela_utilizacao", "ds_utilizacao", [
        ("colaborador_id", "Colaborador", None),
        ("nome", "Nome", None),
        ("papel", "Papel", None),
        ("senioridade", "Senioridade", None),
        ("projeto_id", "Projeto", None),
        ("horas_disponiveis", "Horas disponíveis", None),
        ("horas_apontadas", "Horas apontadas", None),
        ("utilizacao", "Utilização", PERCENTUAL),
        ("custo_ocioso", "Custo ocioso", REAIS),
    ], "Utilização por pessoa e projeto · da mais parada à mais ocupada", pos(0, 10, 12, 9)),
])

# =============================================================================
# Página 3 · Fornecedores (pergunta 4, parte da noite 3)
# =============================================================================
fornecedores = pagina("fornecedores", "Fornecedores", [
    texto("titulo_fornecedores",
          "## O que vai dar errado no próximo mês? As consultorias que não entregam",
          pos(0, 0, 12, 1)),
    texto("subtitulo_fornecedores",
          "Entregas das consultorias: prometido × entregue. Em atraso = em aberto com a data prometida antes de 16/10/2026.",
          pos(0, 1, 12, 1)),
    tabela("tabela_fornecedores", "ds_fornecedores", [
        ("fornecedor", "Fornecedor", None),
        ("grafias_no_cadastro", "Grafias no cadastro", None),
        ("entregas", "Entregas", None),
        ("prazo_real_sobre_prometido", "Prazo real ÷ prometido", INDICE),
        ("pct_no_prazo", "% no prazo", PERCENTUAL),
        ("em_atraso_hoje", "Em atraso hoje", None),
    ], "Desempenho por fornecedor", pos(0, 2, 12, 6)),
    tabela("tabela_atrasadas", "ds_atrasadas", [
        ("entrega_id", "Entrega", None),
        ("fornecedor", "Fornecedor", None),
        ("projeto_id", "Projeto", None),
        ("item", "Item", None),
        ("valor", "Valor", REAIS),
        ("data_pedido", "Pedido em", None),
        ("data_prometida", "Prometida para", None),
        ("dias_de_atraso", "Dias de atraso", None),
    ], "Entregas em atraso hoje", pos(0, 8, 12, 6)),
])

dashboard = {
    "datasets": [dataset(n, t, s) for n, (t, s) in DATASETS.items()],
    "pages": [portfolio, pessoas, fornecedores],
    "uiSettings": {
        "theme": {
            "canvasBackgroundColor": {"light": "#F5F7FA", "dark": FUNDO_ESCURO},
            "widgetBackgroundColor": {"light": "#FFFFFF", "dark": "#1C1C24"},
            "widgetBorderColor":     {"light": "#FFFFFF", "dark": "#1C1C24"},
            "fontColor":             {"light": "#14141A", "dark": "#E8ECF0"},
            "selectionColor":        {"light": AZUL, "dark": CIANO},
            "visualizationColors": [AZUL, CIANO, "#F6C344", "#FF5F46", "#8E6CEF",
                                    "#2BB673", "#F28E2C", "#9AA5B1"],
            "widgetHeaderAlignment": "LEFT",
        }
    },
}

SAIDA.write_text(json.dumps(dashboard, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
n_widgets = sum(len(p["layout"]) for p in dashboard["pages"])
print(f"{SAIDA.relative_to(SAIDA.parent.parent)}: {len(dashboard['datasets'])} datasets, "
      f"{len(dashboard['pages'])} páginas, {n_widgets} widgets")
