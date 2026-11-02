Continue o bundle na raiz deste repositório. O job está pronto e a gold
atualizada. Agora o dashboard, como código. Use a skill
databricks-aibi-dashboards.

1. scripts/gerar_dashboard.py gera resources/dashboard-portfolio.lvdash.json
   (AI/BI, GRID_V1). As queries da gold usam o nome de tabela PURO, sem
   catálogo nem schema; a silver.entregas_fornecedor vai com o nome completo
   lakehouse_vertice.silver.entregas_fornecedor. Três páginas:

   Portfólio
   - KPIs da carteira em andamento, calculados na projeto_situacao_atual
     (WHERE status = 'em_andamento'): carteira (SUM(valor_contrato)), SPI
     (SUM(ev)/SUM(pv)), CPI (SUM(ev)/SUM(ac)), estouro previsto, projetos em
     risco (atenção + crítico), críticos e melancias. Razão é SUM/SUM, nunca
     AVG de razão.
   - barra de estouro previsto por projeto, colorida por situação
     (crítico #FF5F46, atenção #F6C344, ok #22C2F4)
   - dispersão SPI × CPI, um ponto por projeto
   - linha de SPI e CPI semanais da carteira (SUM(ev)/SUM(pv) por semana no
     fato_projeto_semana, a partir de 2025-03-07)
   - tabela dos projetos em andamento com o farol do gerente ao lado do
     farol pelo número e a coluna melancia

   Pessoas
   - top 15 pessoas por custo da hora parada (utilizacao_pessoa_semana,
     semana > 2026-07-24, as últimas 12 semanas)
   - tabela de utilização por pessoa e projeto, da mais parada à mais ocupada
   - barras de causas de bloqueio por projeto (status_estruturado, últimos
     90 dias, sem 'sem_bloqueio' e 'nao_reportado')

   Fornecedores (sobre silver.entregas_fornecedor)
   - tabela por fornecedor: grafias no cadastro, entregas, prazo real ÷
     prometido, % no prazo, em atraso hoje
   - tabela das entregas em atraso hoje

   Tema nas cores da Jornada: #0059DB, #22C2F4, fundo #14141A no escuro.
   Um título de texto em cada página com a pergunta do dono que ela responde.

2. resources/dashboard.dashboard.yml: recurso dashboard_portfolio, display
   name "Projeto Farol · Portfólio", file_path para o JSON, dataset_catalog
   ${var.catalog}, dataset_schema gold, warehouse_id ${var.warehouse_id}.

Antes do deploy, rode cada query do dashboard (prefixando
lakehouse_vertice.gold. nas tabelas da gold) e me mostre a contagem de linhas
de cada uma e os valores dos KPIs.

Rode e me mostre a saída:
  python3 scripts/gerar_dashboard.py
  databricks bundle validate --profile DEFAULT
  databricks bundle deploy --profile DEFAULT
  databricks bundle summary --profile DEFAULT