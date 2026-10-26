# Runbook de produção: histórico de alterações do Lead STech (CLICKUP-11734)

Quem executa: administrador de produção. Org: "Produção Grupo Arnone".
Os passos P1 e P4 são manuais. `objects/Lead/Lead.object-meta.xml` não é promovido, porque carrega OWD
e configurações que divergem entre ambientes, e `profiles/**` está no `.forceignore`.

## Ordem

### P1. Ligar o histórico do objeto Lead (manual, ANTES do deploy)
1. Setup › Object Manager › Lead › Fields & Relationships › Set History Tracking.
2. Marque "Enable Lead History" › Save.
3. Na mesma tela, confira os campos que já estão marcados. O Lead tem 20 vagas, compartilhadas por
   todas as BUs, e este card usa as 20. Se houver algum campo marcado fora da lista abaixo, pare e
   leve ao arquiteto.

Sem P1, o deploy dos campos com `trackHistory=true` pode falhar.

### P2. Promover os metadados (pipeline `dev → uat → production`)
- 18 CustomField de Lead com `trackHistory=true`: LeadSource, Unidade_Origem__c,
  STE_Classificacao_Fila__c, STE_Motivo_Desqualificacao__c, Name, Email, MobilePhone, CPF__c,
  STE_Aceite_Comunicacoes__c, STE_Etapa_Bot__c, STE_Retomadas_Enviadas__c, STE_Possui_CNH__c,
  STE_CNH_Enviada__c, STE_CNH_Status__c, STE_Data_Envio_CNH__c, STE_Prazo_Envio_CNH__c,
  STE_CNH_Validada__c, MotivoDaCNHNOValidada__c. `Status` e `OwnerId` já são rastreados.
- FlexiPage `Lead_STE`, com a aba "Histórico".
- Layout `Lead-Lead STech Layout` (nome "Lead STech Layout"). É uma cópia do `Lead-Lead Layout`
  com a related list de histórico de campos (`RelatedEntityHistoryList`) acrescentada.

Por que existe o layout próprio: o componente Related List - Single da FlexiPage só exibe related
lists presentes no page layout atribuído ao registro. O `Lead-Lead Layout` é compartilhado por todas
as BUs e não tem o histórico de campos.

Se o layout não subir pela pipeline, crie-o à mão: Setup › Object Manager › Lead › Page Layouts ›
New › Existing Page Layout = "Lead Layout" › Page Layout Name = "Lead STech Layout" › Save.
Em seguida, na paleta "Related Lists", arraste "Lead History" para a área de listas relacionadas e
salve. Não altere o "Lead Layout".

### P3. Conferir o layout antes da atribuição
Antes de atribuir, compare em produção o "Lead Layout" com o "Lead STech Layout". O layout novo é cópia
do layout da ArnoneDev de 26/10/2026. Se o "Lead Layout" de produção tiver campos ou seções diferentes,
replique essas diferenças no "Lead STech Layout" antes do P4.

### P4. Atribuir o layout ao tipo de registro STE (manual)
1. Setup › Object Manager › Lead › Page Layouts › Page Layout Assignment › Edit Assignment.
2. Na coluna do tipo de registro "Instituto STech" (`Lead.STE`), selecione "Lead STech Layout" nos
   perfis **System Administrator** e **Standard User**.
3. Não altere as demais colunas (master e `Lead.SOL`), que continuam em "Lead Layout".
4. Save.

Na ArnoneDev, só esses dois perfis têm usuários humanos com acesso a `Lead.STE`. O acesso vem dos
permission sets `PS_STE_Comercial`, `PS_Comercial`, `PS_SDR`, `PS_Admin` e `PS_STE_Bot_Runtime`.
Em produção, consulte quem tem esses PS e inclua na atribuição qualquer outro perfil de usuário humano.

### P5. Página STech atual
Enquanto a `Lead_STE` não estiver ativa em produção para o tipo de registro STE, a página atual
(`Lead_Record_Page_STech_Atendimento`) recebe a mesma aba "Histórico": Lightning App Builder ›
tabset principal › nova aba "Histórico" › componente "Related List - Single", com Related List =
"Lead History", tipo padrão e 10 registros.

## Verificação
1. Abra um Lead do Instituto STech › aba "Histórico". As alterações aparecem com campo, valor
   anterior, valor novo, usuário e data/hora. "Ver tudo" abre a lista completa.
2. Abra um Lead da Arnone Soluções. A página continua no "Lead Layout", sem mudança visível.

## Rollback
1. Page Layout Assignment: volte `Lead.STE` para "Lead Layout" nos dois perfis.
2. Retire a aba "Histórico" da FlexiPage.
3. Opcional: desmarque os campos em Set History Tracking. O histórico já gravado é mantido até
   expirar.
