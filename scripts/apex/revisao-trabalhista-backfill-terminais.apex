// Revisão trabalhista — BACKFILL dos registros TERMINAIS (Opp fechada / Lead
// convertido).
//
// ATENÇÃO: rodar SOMENTE com estes flows DESATIVADOS (senão marcos/perdas
// re-disparam e duplicam contadores/eventos, e Amount/encerramento mudam):
//   SOL_Marco_Perda_Oportunidade, SOL_Encerrar_Tarefas_Oportunidade_Perdida,
//   SOL_Marco_Encerramento_Oportunidade, SOL_Encerrar_Fechamento_Ganho_Perdido,
//   SOL_Negociacao_Valor
// e com o snapshot (revisao-trabalhista-snapshot-terminais.apex) tirado antes.
// Depois: reativar EXATAMENTE as mesmas versões e repetir o snapshot.
Id jobLead = Database.executeBatch(new SOLProdutoBackfillBatch('Lead', true), 200);
Id jobOpp = Database.executeBatch(new SOLProdutoBackfillBatch('Opportunity', true), 200);
System.debug('Backfill TERMINAIS — Lead: ' + jobLead + ' | Opportunity: ' + jobOpp);
