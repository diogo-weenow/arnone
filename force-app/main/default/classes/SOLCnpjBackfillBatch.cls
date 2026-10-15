/**
 * Upload enriquecimento Lemit — backfill ÚNICO de Lead.SOL_CNPJ_Normalizado__c.
 *
 * Preenche o CNPJ normalizado nos Leads PREEXISTENTES (criados antes do Flow
 * before-save Lead_BeforeSave_Normalizar_CNPJ). Rode UMA vez após o deploy; não
 * agende. Idempotente: só grava quando o normalizado calculado difere do atual,
 * então reexecutar não causa dano.
 *
 * `without sharing` e DML em contexto de sistema de propósito: é manutenção
 * administrativa sobre toda a base, independente de compartilhamento, rodada
 * pelo admin. Não altera CNPJ__c nem qualquer outro campo; como o CNPJ não muda,
 * o Flow before-save não reprocessa e nenhuma automação de funil é disparada.
 */
public without sharing class SOLCnpjBackfillBatch implements Database.Batchable<SObject> {
  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(
      [
        SELECT Id, CNPJ__c, SOL_CNPJ_Normalizado__c
        FROM Lead
        WHERE CNPJ__c != NULL
      ]
    );
  }

  public void execute(
    Database.BatchableContext bc,
    List<Lead> escopo
  ) {
    List<Lead> paraAtualizar = new List<Lead>();
    for (Lead l : escopo) {
      String norm = SOLEnriquecimentoUtil.normalizarCnpj(l.CNPJ__c);
      if (norm.length() > 14) {
        norm = norm.substring(0, 14);
      }
      String atual = l.SOL_CNPJ_Normalizado__c == null
        ? ''
        : l.SOL_CNPJ_Normalizado__c;
      if (norm != atual) {
        paraAtualizar.add(
          new Lead(Id = l.Id, SOL_CNPJ_Normalizado__c = norm)
        );
      }
    }
    if (!paraAtualizar.isEmpty()) {
      // Partial success: um Lead problemático não aborta o lote.
      Database.update(paraAtualizar, false);
    }
  }

  public void finish(Database.BatchableContext bc) {
    // Sem pós-processamento. Log de conclusão fica no AsyncApexJob.
  }
}
