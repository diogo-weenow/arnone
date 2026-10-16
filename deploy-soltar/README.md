# PASSO 1 — SOLTAR (versões temporárias para liberar o flip de tipo)

Conjunto de deploy **temporário** usado SÓ durante a janela do flip dos campos
`Lead.SOL_Produto_Interesse__c` e `Opportunity.SOL_Produto_Negocio__c` de
Picklist para Multi-Select Picklist.

## Por que existe
O flip de tipo é bloqueado (UI e API) enquanto qualquer VR/Flow referencia o
campo numa fórmula. Estas versões **removem a referência ao campo** (field-free),
para que o campo fique sem dependências de fórmula e o wizard "Change Field Type"
da Setup UI libere a conversão. Depois do flip, o PASSO 3 restaura as versões
finais (com `INCLUDES`).

## O que cada artefato faz na janela
- **VRs** `FALSE` no lugar do termo de produto → a regra NÃO dispara durante a
  janela (janela curta, com schedulers desagendados). Exceção:
  `SOL_Conversao_Exige_Procuracao_Ou_Apto` mantém a trava de procuração para
  TODOS os leads SOL (comportamento de main), sem o gate de produto.
- **Flows** `FALSE` no termo de produto da `filterFormula` → o flow NÃO dispara
  durante a janela.

## Como deployar (PASSO 1)
```
sf project deploy start --source-dir deploy-soltar --target-org <org> --test-level NoTestRun
```
Valida/deploya 18 componentes (8 VRs + 10 Flows). Dry-run confirmado: 18/18, sem falhas.

## IMPORTANTE — versões obsoletas de Flow
Deployar estas versões torna a versão ANTERIOR de cada flow **obsoleta**, mas a
obsoleta AINDA referencia o campo e permanece no índice de dependências. Se o
wizard de flip ainda listar flows (inclusive o fantasma `SOL_Procuracao`, cuja
versão ativa já é field-free), é preciso DELETAR as versões obsoletas que
referenciam o campo. Ver o runbook (PASSO 1b) e o self-check por
`MetadataComponentDependency`.

## Não faz parte do pacote principal
Esta pasta fica FORA de `force-app/` e não é apanhada por um deploy padrão do
projeto. É descartável: após o PASSO 3, nada daqui precisa ficar na org.
