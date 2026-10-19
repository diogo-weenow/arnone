# Salesforce DX Project: Next Steps

Now that you’ve created a Salesforce DX project, what’s next? Here are some documentation resources to get you started.

## How Do You Plan to Deploy Your Changes?

Do you want to deploy a set of changes, or create a self-contained application? Choose a [development model](https://developer.salesforce.com/tools/vscode/en/user-guide/development-models).

## Configure Your Salesforce DX Project

The `sfdx-project.json` file contains useful configuration information for your project. See [Salesforce DX Project Configuration](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_ws_config.htm) in the _Salesforce DX Developer Guide_ for details about this file.

## Read All About It

- [Salesforce Extensions Documentation](https://developer.salesforce.com/tools/vscode/)
- [Salesforce CLI Setup Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm)
- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_intro.htm)
- [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/cli_reference.htm)

## Pipeline de deploy (main → UAT)

O workflow [`.github/workflows/deploy-uat.yml`](.github/workflows/deploy-uat.yml) propaga
para a sandbox `arnone-uat` tudo que entra na `main` (ou seja, a cada merge de PR).

### Como funciona

1. Dispara no `push` para a `main` quando há mudança em `force-app/**` ou `sfdx-project.json`.
2. Calcula o **delta** com [`sfdx-git-delta`](https://github.com/scolladon/sfdx-git-delta):
   compara o commit anterior da `main` (`github.event.before`) com o novo e monta um
   `package.xml` só com o que mudou — não faz deploy do org inteiro.
3. Faz `sf project deploy start --manifest delta/package/package.xml` na `arnone-uat`.
4. Publica no resumo do job o `package.xml` aplicado.

Um `concurrency group` garante um deploy por vez: dois merges seguidos entram em fila
em vez de disputar a org.

### Remoções de metadados

Deleções **não são aplicadas automaticamente**. O `destructiveChanges.xml` gerado aparece
no resumo do job com um aviso, para deploy destrutivo manual e revisado — evita perda de
dados na UAT por um arquivo removido sem intenção.

### Setup (uma vez)

O workflow precisa do secret `SF_AUTH_URL_UAT` com a Salesforce DX auth URL da org de UAT.

```bash
sf org display --target-org arnone-uat --verbose --json | jq -r '.result.sfdxAuthUrl' | gh secret set SF_AUTH_URL_UAT --repo diogo-weenow/arnone
```

> A auth URL contém o refresh token da org — só existe no secret do GitHub, nunca no repo.
> Se a sandbox for refreshada ou o token revogado, rode o comando de novo.

Para mais controle (timeout de refresh token, IP ranges, sem dependência de login web),
o caminho é trocar por um Connected App com certificado digital e usar
`sf org login jwt` com os secrets `SF_CONSUMER_KEY`, `SF_USERNAME` e `SF_JWT_KEY`.

### Execução manual

Em **Actions → Deploy UAT → Run workflow**, com opções de:

- `test_level`: `NoTestRun` (padrão), `RunLocalTests` ou `RunAllTestsInOrg`
- `from_ref`: commit/tag inicial do delta (para reprocessar um intervalo)
- `dry_run`: valida o deploy sem aplicar na org
