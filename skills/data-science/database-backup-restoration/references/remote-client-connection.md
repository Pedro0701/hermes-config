# Conexão Remota (DBeaver / Qualquer Cliente SQL)

Após restaurar um backup, o usuário pergunta **como conectar do PC cliente**.
Este guia cobre os 3 SGBDs, as credenciais fixas e as configurações específicas
de cada driver.

## Visão geral

| SGBD | Container | Porta (host) | Usuário | Senha (do `.env`) |
|------|-----------|-------------|---------|-------------------|
| SQL Server | `sqlserver_migrados` | **1433** | `sa` | `SA_PASSWORD` |
| MySQL | `mysql_migrados` | **3307** | `root` | `MYSQL_ROOT_PASSWORD` |
| PostgreSQL | `postgres_migrados` | **5432** | `postgres` | `POSTGRES_PASSWORD` |

## IP da VM

Descobrir com:

```bash
hostname -I | awk '{print $1}'
```

O IP costuma ser local (ex.: `192.168.x.x`). O PC cliente precisa estar na
mesma rede (mesmo roteador ou VPN).

## DBeaver — Configurações Específicas

### SQL Server (porta 1433)

- **Driver:** MSSQL (SQL Server)
- **Host:** IP da VM
- **Porta:** 1433
- **Database:** deixar em branco ou selecionar após conectar
- **Authentication:** SQL Server Auth — usuário `sa`, senha do `.env`
- **Driver properties obrigatórias** (sem isso a conexão falha no SQL Server 2022):
  - `trustServerCertificate=true` — ou
  - `encrypt=false` (depende da versão do driver JDBC)
- **Testar conexão** antes de OK

### MySQL (porta 3307 — NÃO é a padrão 3306)

- **Driver:** MySQL
- **Host:** IP da VM
- **Porta:** **3307** (alterar do padrão 3306)
- **Database:** deixar em branco ou selecionar após conectar
- **User:** `root`
- **Password:** do `.env`
- **Driver properties:** não precisa de configurações extras

### PostgreSQL (porta 5432)

- **Driver:** PostgreSQL
- **Host:** IP da VM
- **Porta:** 5432
- **Database:** `postgres` (ou o banco customizado)
- **User:** `postgres`
- **Password:** do `.env`

## Listar bancos disponíveis

Após a conexão, o usuário pode listar os bancos para ver o que foi restaurado:

### SQL Server
```sql
SELECT name FROM sys.databases ORDER BY name;
```

### MySQL
```sql
SHOW DATABASES;
```

### PostgreSQL
```bash
docker exec postgres_migrados psql -U postgres -l
```

## Troubleshooting

### Conexão recusada / timeout

1. Verificar se o container está rodando:
   ```bash
   docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
   ```
2. Verificar se a porta está ouvindo em `0.0.0.0`:
   ```bash
   ss -tlnp | grep -E '(:1433|:3307|:5432)'
   ```
3. Se estiver ouvindo só em `127.0.0.1`, o container não expôs a porta para
   a rede. Verificar `docker inspect` ou as portas no `docker-compose.yml`.
4. Testar conectividade do PC cliente:
   ```bash
   ping <IP_DA_VM>
   telnet <IP_DA_VM> 1433
   ```
5. Se o firewall da VM estiver ativo, liberar as portas:
   ```bash
   sudo ufw allow 1433/tcp
   sudo ufw allow 3307/tcp
   sudo ufw allow 5432/tcp
   ```

### SQL Server — "The driver could not establish a secure connection"

Causa: SQL Server 2022 exige criptografia por padrão. O driver JDBC do DBeaver
precisa de `trustServerCertificate=true`.

**Onde configurar:** DBeaver → Editar conexão → Driver properties →
`trustServerCertificate` = `true`.

Alternativa: na connection string JDBC:
```
jdbc:sqlserver://192.168.x.x:1433;trustServerCertificate=true;encrypt=true
```

### MySQL — "Public Key Retrieval is not allowed"

Se o MySQL 8.0 reclamar de `caching_sha2_password`:
- Driver properties → `allowPublicKeyRetrieval` = `true`
- Ou no DBeaver: aba Driver properties → marcar `allowPublicKeyRetrieval = true`

### PostgreSQL — "no pg_hba.conf entry"

Adicionar ou alterar no container:
```bash
docker exec postgres_migrados sh -c "echo 'host all all 0.0.0.0/0 md5' >> /var/lib/postgresql/data/pg_hba.conf"
docker restart postgres_migrados
```

## Credenciais (do `.env`)

Ler sem expor no terminal:

```bash
grep -E '^(SA_PASSWORD|MYSQL_ROOT_PASSWORD|POSTGRES_PASSWORD)=' \
  /home/hermes/conversor-backups/sistemas_migrados/.env
```

## Informar ao usuário

Template de mensagem para o usuário (Telegram ou chat):

```
✅ Banco restaurado com sucesso!

🗄️ SGBD: SQL Server
🌐 Host: <IP>:1433
🗂️ Banco: <nome_banco>
👤 Usuário: sa
🔑 Senha: <senha>

Conecte com DBeaver ou qualquer cliente SQL.
Para SQL Server, marque "Trust Server Certificate" no driver.
```