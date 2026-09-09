# Pipelines

Todas usam [`sfdx-git-delta`](https://github.com/scolladon/sfdx-git-delta) para montar um
`package.xml` só com o que mudou. O `force-app` deste repo é um retrieve completo do org
(~7,7 mil arquivos, incluindo objetos standard, profiles e sites); um deploy full falharia.

| Workflow | Dispara em | Org | Aplica? |
|---|---|---|---|
| [`validate-pr.yml`](validate-pr.yml) | PR contra `main` | `arnone-uat` | Não — dry-run |
| [`deploy-uat.yml`](deploy-uat.yml) | push na `main` (merge de PR) | `arnone-uat` | Sim |
| [`deploy-prod.yml`](deploy-prod.yml) | push na `production` (merge de PR) | `arnone-prod` | Sim, após aprovação |

## Fluxo

```
feature/xxx ──PR──> main ──PR──> production
     │               │              │
 validate-pr    deploy-uat     deploy-prod
 (dry-run na    (delta na      (valida com testes →
  UAT, comenta   UAT)           aprovação → aplica)
  no PR)
```

As duas branches longas são espelhos de org: `main` reflete a `arnone-uat`, `production`
reflete a `arnone-prod`. Promover para produção é abrir um PR de `main` para `production`.

## `validate-pr.yml`

Valida na `arnone-uat` sem aplicar nada, e comenta o resultado no próprio PR (comentário
fixo, editado a cada push em vez de empilhar um por commit).

O nível de teste sai do conteúdo do delta: `RunLocalTests` quando o PR mexe em
`ApexClass`/`ApexTrigger`, `NoTestRun` quando não — não faz sentido gastar minutos rodando
a bateria inteira num PR que só mexe em layout ou relatório.

> O repositório é público: PR vindo de **fork** não recebe os secrets e por isso não é
> validado. Só PR de branch deste repo dispara o workflow.

## `deploy-uat.yml`

Delta entre o commit anterior da `main` (`github.event.before`) e o novo. Um
`concurrency group` serializa deploys: dois merges seguidos entram em fila em vez de
disputar a org.

## `deploy-prod.yml`

Merge na branch `production` significa deployar. O delta sai de `github.event.before` — o
topo anterior da branch, ou seja, o que já está na org — até o novo commit.

São dois jobs, de propósito:

**`validar`** — roda `sf project deploy validate` com `RunLocalTests` na produção. Não muda
nada na org, então roda **sem esperar aprovação**: se um teste quebra, ninguém foi incomodado
para aprovar um deploy que ia falhar. Guarda o `package.xml` como artifact por 30 dias.

**`aplicar`** — gated pelo environment `production`, que exige revisor obrigatório. O run
fica parado aqui até alguém aprovar no GitHub. Aí roda `sf project deploy quick` sobre o
pacote já validado: aplica em minutos, **sem reexecutar a bateria de testes**.

### Primeiro deploy

A branch `production` foi criada a partir do topo da `main`, o que declara que produção está
idêntica à UAT neste momento. Se a org de produção estiver de fato **atrás** disso, o primeiro
delta sairia errado (pequeno demais). Nesse caso, antes do primeiro merge:

- resete a branch para o commit que representa o estado real da produção, **ou**
- rode o workflow manualmente (`workflow_dispatch`) informando `from_ref` com esse commit.

### Aprovação

Configurada em Settings → Environments → `production`:

- **Required reviewer**: `diogo-weenow`. O job `aplicar` não roda sem aprovação.
- **Deployment branch policy**: só a branch `production` pode deployar nesse environment.

Para exigir mais de um aprovador, ou aprovação por equipe, é só adicionar reviewers ali —
nenhuma mudança de código é necessária.

## Secrets

| Secret | Para quê |
|---|---|
| `SF_AUTH_URL_UAT` | `validate-pr.yml` e `deploy-uat.yml` |
| `SF_AUTH_URL_PROD` | `deploy-prod.yml` (ambos os jobs) |

```bash
sf org display --target-org arnone-uat --verbose --json | jq -r '.result.sfdxAuthUrl' \
  | gh secret set SF_AUTH_URL_UAT --repo diogo-weenow/arnone

sf org display --target-org arnone-prod --verbose --json | jq -r '.result.sfdxAuthUrl' \
  | gh secret set SF_AUTH_URL_PROD --repo diogo-weenow/arnone
```

`SF_AUTH_URL_PROD` é secret **de repositório**, não do environment: o job `validar` precisa
dele e roda antes do portão de aprovação. O portão protege a aplicação, não a leitura —
validar não altera a org.

> A auth URL carrega o refresh token da org — vive só no secret, nunca no repo. Se a org for
> refreshada ou o token revogado, rode o comando de novo.

Para mais controle (timeout de refresh token, IP ranges, sem dependência de login web), o
caminho é um Connected App com certificado digital e `sf org login jwt`, com os secrets
`SF_CONSUMER_KEY`, `SF_USERNAME` e `SF_JWT_KEY`.

## Remoções de metadados

Nenhuma pipeline aplica deleção. O `destructiveChanges.xml` gerado pelo delta aparece com
aviso no comentário do PR e no resumo do job, para deploy destrutivo manual e revisado —
evita perder dados por um arquivo removido sem intenção.
