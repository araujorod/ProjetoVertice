#!/usr/bin/env python3
"""Executa um arquivo .sql no Databricks, uma statement por vez.

Usa a API de SQL Statements (`databricks api post /api/2.0/sql/statements`)
em vez de `aitools tools query`: a segunda achata a indentação do texto e
quebra o YAML das metric views (`CREATE VIEW ... WITH METRICS`).

Uso:
  python3 scripts/run_sql.py <arquivo.sql> --profile <perfil> [--warehouse ID] [--quiet] [--continuar]
"""
import argparse, json, subprocess, sys, time


def dividir(sql: str) -> list[str]:
    """Divide em statements, ignorando ';' dentro de string, comentário ou bloco $$."""
    stmts, atual, i = [], [], 0
    aspas = dolar = False
    while i < len(sql):
        if not aspas and sql.startswith("$$", i):
            dolar = not dolar
            atual.append("$$")
            i += 2
            continue
        c = sql[i]
        if not aspas and not dolar and sql.startswith("--", i):
            fim = sql.find("\n", i)
            fim = len(sql) if fim == -1 else fim
            atual.append(sql[i:fim])
            i = fim
            continue
        if c == "'" and not dolar:
            aspas = not aspas
        if c == ";" and not aspas and not dolar:
            stmts.append("".join(atual))
            atual, i = [], i + 1
            continue
        atual.append(c)
        i += 1
    stmts.append("".join(atual))
    return [s.strip() for s in stmts
            if any(l.strip() and not l.strip().startswith("--") for l in s.splitlines())]


def cli(args: list[str], profile: str) -> dict:
    r = subprocess.run(["databricks", *args, "--profile", profile, "-o", "json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    return json.loads(r.stdout or "{}")


def warehouse_padrao(profile: str) -> str:
    whs = cli(["warehouses", "list"], profile)
    whs = whs if isinstance(whs, list) else whs.get("warehouses", [])
    if not whs:
        sys.exit("nenhum SQL warehouse encontrado")
    return whs[0]["id"]


def executar(stmt: str, warehouse: str, profile: str) -> dict:
    corpo = json.dumps({"warehouse_id": warehouse, "statement": stmt,
                        "wait_timeout": "50s", "on_wait_timeout": "CONTINUE"})
    r = cli(["api", "post", "/api/2.0/sql/statements", "--json", corpo], profile)
    while r["status"]["state"] in ("PENDING", "RUNNING"):
        time.sleep(3)
        r = cli(["api", "get", f"/api/2.0/sql/statements/{r['statement_id']}"], profile)
    return r


def imprimir(r: dict, limite: int = 30) -> None:
    cols = [c["name"] for c in r.get("manifest", {}).get("schema", {}).get("columns", [])]
    linhas = r.get("result", {}).get("data_array") or []
    if not cols or not linhas:
        return
    print("  " + " | ".join(cols))
    for l in linhas[:limite]:
        print("  " + " | ".join("" if v is None else str(v) for v in l))
    if len(linhas) > limite:
        print(f"  ... ({len(linhas)} linhas)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("arquivo")
    ap.add_argument("--profile", required=True, help="profile do ~/.databrickscfg (sempre explícito)")
    ap.add_argument("--warehouse", help="id do SQL warehouse (padrão: o primeiro da lista)")
    ap.add_argument("--quiet", action="store_true", help="não imprime o resultado, só o status")
    ap.add_argument("--continuar", action="store_true",
                    help="segue mesmo se uma statement falhar (há queries que quebram de propósito)")
    args = ap.parse_args()

    wh = args.warehouse or warehouse_padrao(args.profile)
    stmts = dividir(open(args.arquivo, encoding="utf-8").read())
    print(f"{args.arquivo}: {len(stmts)} statement(s) · warehouse {wh}\n")

    falhas = 0
    for n, stmt in enumerate(stmts, 1):
        titulo = next((l.strip() for l in stmt.splitlines()
                       if l.strip() and not l.strip().startswith("--")), "")[:70]
        print(f"[{n}/{len(stmts)}] {titulo}")
        try:
            r = executar(stmt, wh, args.profile)
        except RuntimeError as e:
            r = {"status": {"state": "FAILED", "error": {"message": str(e)}}}
        if r["status"]["state"] != "SUCCEEDED":
            falhas += 1
            print(f"  FALHOU: {r['status'].get('error', {}).get('message', r['status'])}\n")
            if not args.continuar:
                return 1
            continue
        if not args.quiet:
            imprimir(r)
        print("  ok\n")
    return 1 if falhas and not args.continuar else 0


if __name__ == "__main__":
    sys.exit(main())
