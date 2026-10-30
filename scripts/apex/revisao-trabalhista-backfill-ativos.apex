// Revisão trabalhista — BACKFILL dos registros ATIVOS (Opp aberta / Lead não
// convertido). Seguro com os flows ativos: nenhum flow terminal re-dispara.
// Idempotente. Rodar uma vez após o deploy.
Id jobLead = Database.executeBatch(new SOLProdutoBackfillBatch('Lead'), 200);
Id jobOpp = Database.executeBatch(new SOLProdutoBackfillBatch('Opportunity'), 200);
System.debug('Backfill ATIVOS — Lead: ' + jobLead + ' | Opportunity: ' + jobOpp);
