# Pipelines

Todas usam [`sfdx-git-delta`](https://github.com/scolladon/sfdx-git-delta) para montar um
`package.xml` só com o que mudou. O `force-app` deste repo é um retrieve completo do org
(~7,7 mil arquivos, incluindo objetos standard, profiles e sites); um deploy full falharia.

| Workflow | Dispara em | Org | Aplica? |
|---|---|---|---|
| [`validate-pr.yml`](validate-pr.yml) | PR contra `main` | `arnone-uat` | Não — dry-run |
| [`deploy-uat.yml`](deploy-uat.yml) | push na `main` (merge de PR) | `arnone-uat` | Sim |
| [`deploy-prod.yml`](deploy-prod.yml) | manual, em dois passos | `arnone-prod` | Só no 2º passo |

## Fluxo

```
feature/xxx ──PR──> main ──merge──> UAT ──manual──> Produção
             │                       │               │
        validate-pr              deploy-uat     deploy-prod
        (dry-run,                (delta         (validate →
         comenta no PR)           automático)    quick-deploy)
```

## `validate-pr.yml`

Valida na `arnone-uat` sem aplicar nada, e comenta o resultado no próprio PR (comentário
fixo, editado a cada push em vez de empilhar um por commit).

O nível de teste é escolhido pelo conteúdo do delta: `RunLocalTests` quando o PR mexe em
`ApexClass`/`ApexTrigger`, `NoTestRun` quando não — não faz sentido gastar minutos rodando
a bateria inteira num PR que só mexe em layout ou relatório.

## `deploy-uat.yml`

Delta entre o commit anterior da `main` (`github.event.before`) e o novo. Um
`concurrency group` serializa deploys: dois merges seguidos entram em fila em vez de
disputar a org.

## `deploy-prod.yml`

Produção nunca sai de um merge automático. São dois disparos manuais deliberados, no padrão
recomendado pela Salesforce:

**Passo 1 — `modo: validate`**

Valida na produção com `sf project deploy validate` e `RunLocalTests`. O delta parte da tag
`prod`, que marca o que já está em produção. O resumo do job devolve um **job id** válido
por 10 dias.

> No primeiro uso não existe a tag `prod`. Informe `from_ref` com o commit ou tag que
> representa o estado atual da produção — a pipeline recusa rodar sem isso, para não tentar
> deployar o repositório inteiro.

**Passo 2 — `modo: quick-deploy`**

No **mesmo ref**, informe o `job_id` do passo 1 e digite `DEPLOY PRODUCAO` em `confirmacao`.
Roda `sf project deploy quick`, que aplica o pacote já validado **sem reexecutar os testes** —
deploy de minutos em vez de uma hora. Ao final, move a tag `prod` para o commit deployado.

### Aprovação por revisor

O workflow declara `environment: production`. O plano atual do GitHub **não permite required
reviewers em repositório privado** — a API recusa com *"Please ensure the billing plan supports
the required reviewers protection rule"*. Hoje o portão é humano por construção: dois disparos
manuais e uma confirmação digitada.

Ao subir para GitHub Pro/Team, basta adicionar o revisor obrigatório no environment
`production` (Settings → Environments) — nenhuma mudança de código é necessária.

## Secrets

| Secret | Onde | Para quê |
|---|---|---|
| `SF_AUTH_URL_UAT` | repositório | `validate-pr.yml` e `deploy-uat.yml` |
| `SF_AUTH_URL_PROD` | environment `production` | `deploy-prod.yml` |

```bash
# UAT (secret de repositório)
sf org display --target-org arnone-uat --verbose --json | jq -r '.result.sfdxAuthUrl' \
  | gh secret set SF_AUTH_URL_UAT --repo diogo-weenow/arnone

# Produção (secret do environment, escopo mais restrito)
sf org display --target-org arnone-prod --verbose --json | jq -r '.result.sfdxAuthUrl' \
  | gh secret set SF_AUTH_URL_PROD --repo diogo-weenow/arnone --env production
```

> A auth URL carrega o refresh token da org — vive só no secret, nunca no repo. Se a sandbox
> for refreshada ou o token revogado, rode o comando de novo.

Para mais controle (timeout de refresh token, IP ranges, sem dependência de login web), o
caminho é um Connected App com certificado digital e `sf org login jwt`, com os secrets
`SF_CONSUMER_KEY`, `SF_USERNAME` e `SF_JWT_KEY`.

## Remoções de metadados

Nenhuma pipeline aplica deleção. O `destructiveChanges.xml` gerado pelo delta aparece com
aviso no comentário do PR e no resumo do job, para deploy destrutivo manual e revisado —
evita perder dados por um arquivo removido sem intenção.
