/**
 * Importação de leads — backfill ÚNICO de Lead.CNPJ_Normalizado__c. Substitui o
 * SOLCnpjBackfillBatch.
 *
 * Preenche o CNPJ normalizado nos Leads PREEXISTENTES (criados antes da nova
 * versão do Flow before-save Lead_BeforeSave_Normalizar_CNPJ). Rode UMA vez após
 * o deploy; não agende. Usa exatamente a regra do Flow (remove '.', '/', '-' e
 * espaço e converte para maiúsculas), sem o zero à esquerda que só a importação
 * aplica, para que o backfill e o Flow gravem o mesmo valor. Idempotente: só
 * grava quando o valor calculado difere do atual.
 *
 * `without sharing` e DML em contexto de sistema de propósito: manutenção
 * administrativa sobre toda a base, rodada pelo admin. Não altera CNPJ__c nem
 * outro campo; como o CNPJ não muda, o Flow não reprocessa.
 */
public without sharing class CnpjNormalizadoBackfillBatch implements Database.Batchable<SObject> {
  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(
      [
        SELECT Id, CNPJ__c, CNPJ_Normalizado__c
        FROM Lead
        WHERE CNPJ__c != NULL
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<Lead> escopo) {
    List<Lead> paraAtualizar = new List<Lead>();
    for (Lead l : escopo) {
      String norm = normalizarComoFlow(l.CNPJ__c);
      String atual = l.CNPJ_Normalizado__c == null ? '' : l.CNPJ_Normalizado__c;
      // equals: comparação sensível a maiúsculas (== em Apex não é).
      if (!norm.equals(atual)) {
        paraAtualizar.add(new Lead(Id = l.Id, CNPJ_Normalizado__c = norm));
      }
    }
    if (!paraAtualizar.isEmpty()) {
      // Partial success: um Lead problemático não aborta o lote.
      Database.SaveResult[] srs = Database.update(paraAtualizar, false);
      for (Database.SaveResult sr : srs) {
        if (!sr.isSuccess()) {
          System.debug(
            LoggingLevel.WARN,
            'CnpjNormalizadoBackfillBatch: ' + sr.getId() + ' ' + sr.getErrors()
          );
        }
      }
    }
  }

  public void finish(Database.BatchableContext bc) {
    // Sem pós-processamento. Log de conclusão fica no AsyncApexJob.
    System.debug(LoggingLevel.INFO, 'CnpjNormalizadoBackfillBatch concluído.');
  }

  /** Mesma regra do Flow: sem pontuação, maiúsculas, no máximo 14 caracteres. */
  @TestVisible
  private static String normalizarComoFlow(String cnpj) {
    if (String.isBlank(cnpj)) {
      return '';
    }
    String s = cnpj.replace('.', '')
      .replace('/', '')
      .replace('-', '')
      .replace(' ', '')
      .toUpperCase();
    return s.length() > 14 ? s.substring(0, 14) : s;
  }
}
