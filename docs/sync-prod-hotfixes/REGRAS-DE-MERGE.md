# Regras de merge — SYNC-PROD-HOTFIXES

Para quem for mergear #47, #48, #49, df-bus e importação. Snapshots de produção em `docs/sync-prod-hotfixes/prod-snapshot/`.

- R1 RecordTypes. Base = versão da feature. Acrescente todo `<picklistValues>` do snapshot cujo `<picklist>` não exista na base:
  - Lead: STE_CNH_Status__c, STE_CNH_Validada__c, STE_Etapa_Bot__c, STE_Motivo_Desqualificacao__c, STE_Recuperacao_Etapa__c, STE_Regioes_De_SP__c;
  - Opportunity: STE_CNH_Status__c, STE_Ja_Trabalhou_Telecom__c, STE_Jornada_PreCurso_Etapa__c, e STE_Motivo_Perda__c em ADV/ESG/SCO/SOL.
  Para picklist presente nos dois lados, faça a união dos valores. Nunca remova valor. Confira: nº de `<picklistValues>` do resultado = união dos dois arquivos.
- R2 Lead Layout. Base = layout enxuto da df-bus, que mantém Industry, NumberOfEmployees, Rating e Website e não tem STE_CPF_Confirmado__c. Acrescente na seção STE: STE_Regioes_De_SP__c (Edit), STE_Progresso_Bot__c (Readonly), STE_Etapa_Bot__c (Readonly), STE_Etapa_Bot_Desde__c (Readonly), STE_Retomadas_Enviadas__c (Readonly), STE_Motivo_Desqualificacao__c (Edit), STE_CNH_Status__c, STE_Aceite_Comunicacoes__c, STE_CNH_Validada__c (Edit), MotivoDaCNHNOValidada__c (Edit). Este layout só vai para produção no mesmo deploy que ativa a `Lead_STE` para Lead.STE. A `Lead_STE` será ajustada depois: sem STE_CPF_Confirmado__c, Industry, NumberOfEmployees, Rating e Website, e com os 10 campos acima.
- R3 Opportunity Layout. Base = df-bus. Acrescente STE_CNH_Status__c (Edit) e STE_Pendencias_Matricula__c (Readonly) na seção STE. Ignore a diferença de `masterLabel` do platformActionList, que é Id da org.
- R4 Arnone.app. União de três fontes:
  - os `actionOverrides` de produção: Lead → Lead_Record_Page_Two_Column e Opportunity → Oportunidade_P_gina_de_registro, Large e Small;
  - os 20 `profileActionOverrides` da df-bus;
  - a aba `Importacao_Leads` da importação.
- R5 Arnone_Atendimento.app. União entre produção (rótulo "Stech Atendimento", `actionOverrides`, `profileActionOverrides`) e a df-bus. Para a chave repetida (Lead, Lead.STE, Admin, Large), mantenha a de produção, `Lead_Record_Page_STech_Atendimento`, até a Parte 2 (apps por BU).
- R6. Os 4 `*.object-meta.xml` (Lead, Opportunity, Account, Contact) nunca são promovidos para produção sem decisão de OWD registrada pelo PO.
