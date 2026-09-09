# Pipelines

Uma branch por org. Merge na branch deploya na org correspondente.

| Branch | Org | Workflow | Portão |
|---|---|---|---|
| `dev` | `arnone-dev` | [`deploy-dev.yml`](deploy-dev.yml) | nenhum |
| `uat` | `arnone-uat` | [`deploy-uat.yml`](deploy-uat.yml) | nenhum |
| `production` | `arnone-prod` | [`deploy-prod.yml`](deploy-prod.yml) | revisor obrigatório |

Promover é abrir PR de uma branch para a próxima:

```
feature/xxx ──PR──> dev ──PR──> uat ──PR──> production
                     │           │            │
              deploy-dev   deploy-uat    deploy-prod
                     └───── validate-pr ─────┘
                     (dry-run na org de destino,
                      comenta no PR, antes do merge)
```

Todas usam [`sfdx-git-delta`](https://github.com/scolladon/sfdx-git-delta) para montar um
`package.xml` só com o que mudou. O `force-app` é um retrieve completo do org (~7,7 mil
arquivos, incluindo objetos standard e settings); um deploy full falharia.

## `validate-pr.yml`

Valida o PR **na org da branch de destino**, sem aplicar nada, e comenta o resultado no
próprio PR (comentário fixo, editado a cada push em vez de empilhar um por commit).

Nível de teste: `RunLocalTests` sempre que o destino é `production` (último portão antes da
org real) ou quando o delta mexe em `ApexClass`/`ApexTrigger`; `NoTestRun` no resto — não faz
sentido gastar minutos num PR que só mexe em layout ou relatório.

> O repositório é público: PR vindo de **fork** não recebe os secrets e por isso não é
> validado.

## `deploy-dev.yml` e `deploy-uat.yml`

Delta entre o topo anterior da branch (`github.event.before`) e o novo commit. Os dois são
cascas finas sobre [`_deploy-delta.yml`](_deploy-delta.yml), que carrega o passo a passo —
um lugar só para corrigir ou versionar o CLI.

Um `concurrency group` por org serializa deploys: dois merges seguidos entram em fila em vez
de disputar a org.

> **A branch `dev` deploya na org de dev.** A branch é a fonte da verdade e sobrescreve a org.
> Trabalho feito direto na org de dev e ainda não commitado pode ser desfeito por um merge —
> commite antes de mergear.

## `deploy-prod.yml`

Não usa o workflow reutilizável: o fluxo é estruturalmente diferente.

**`validar`** — `sf project deploy validate` com `RunLocalTests` na produção. Não muda nada
na org, então roda **sem esperar aprovação**: se um teste quebra, ninguém foi incomodado para
aprovar um deploy que ia falhar. Guarda o `package.xml` como artifact por 30 dias.

**`aplicar`** — gated pelo environment `production`, que exige revisor obrigatório. O run
fica parado até alguém aprovar. Aí roda `sf project deploy quick` sobre o pacote já validado:
aplica em minutos, **sem reexecutar a bateria de testes**.

Configurado em Settings → Environments → `production`:

- **Required reviewer**: `diogo-weenow`
- **Deployment branch policy**: só a branch `production` deploya nesse environment

## Secrets

| Secret | Org |
|---|---|
| `SF_AUTH_URL_DEV` | `arnone-dev` |
| `SF_AUTH_URL_UAT` | `arnone-uat` |
| `SF_AUTH_URL_PROD` | `arnone-prod` |

```bash
for par in DEV:arnone-dev UAT:arnone-uat PROD:arnone-prod; do
  sf org auth show-sfdx-auth-url --target-org "${par#*:}" --json | jq -r '.result.sfdxAuthUrl' \
    | gh secret set "SF_AUTH_URL_${par%%:*}" --repo diogo-weenow/arnone
done
```

> Use `sf org auth show-sfdx-auth-url`, **não** `sf org display --json`: este último **redige** o
> campo e devolve o literal `[REDACTED]...`, que entra no secret sem erro aparente e só falha no
> runner com `INVALID_SFDX_AUTH_URL`. Os workflows agora checam o prefixo `force://` e falham com
> mensagem clara se o secret estiver assim.

> A auth URL carrega o refresh token da org — vive só no secret, nunca no repo. Se a org for
> refreshada ou o token revogado, rode de novo.

A org de produção tem um External Client App (`arnone-ci-prd`) com **JWT Bearer Flow** e
certificado já subido — mecanismo mais robusto que a auth URL, sem refresh token que expira.
Trocar `deploy-prod.yml` para `sf org login jwt` depende de ter a private key correspondente.

## Remoções de metadados

Nenhuma pipeline aplica deleção. O `destructiveChanges.xml` gerado pelo delta aparece com
aviso no comentário do PR e no resumo do job, para deploy destrutivo manual e revisado —
evita perder dados por um arquivo removido sem intenção.

## Estado inicial das orgs

A UAT ainda **não recebeu a camada custom** que existe em dev (98 classes Apex, 65 flows,
objetos `SOL_*`). As pipelines fazem delta do último merge, então **não** carregam esse
acúmulo: a carga inicial é um deploy deliberado, feito fora delas.
