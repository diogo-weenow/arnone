/**
 * CLICKUP-9424 — Card 13: diagnóstico e backfill do prazo total de 30 dias
 * úteis para Oportunidades SOL ANTIGAS (criadas antes deste card).
 *
 * COMO USAR
 *   1) Rode com SIMULAR = true (padrão): só imprime o diagnóstico, não grava.
 *   2) Confira as contagens; rode com SIMULAR = false para gravar.
 *   Execução: `sf apex run --file <este arquivo> --target-org <alias>`.
 *
 * REGRA DO BACKFILL — DETERMINÍSTICO, SEM INFERÊNCIA
 *   A data de início do ciclo vem SEMPRE do Lead convertido, localizado por
 *   Lead.ConvertedOpportunityId, campo Lead.SOL_Data_Contato_Efetivado__c.
 *   NADA é presumido a partir de Opportunity.CreatedDate, de mudança de etapa
 *   ou de reatribuição. Oportunidade sem Lead convertido, ou cujo Lead não tem
 *   contato efetivado registrado, fica DE FORA e é listada no diagnóstico para
 *   tratamento manual.
 *   O limite é calculado com a mesma régua do runtime
 *   (SOLPrazoTotalService.calcularPrazoTotal → SOLBusinessHoursHelper).
 *
 * ESCOPO
 *   Record Type SOL, produto "Recuperação Tributária" ou "ART 360",
 *   Oportunidades ABERTAS (IsClosed = false). Fechadas não precisam de prazo.
 *
 * SEGURANÇA
 *   - Não altera proprietário, etapa, marcos nem Tasks: grava apenas
 *     SOL_Data_Inicio_Ciclo_Comercial__c e SOL_Prazo_Total_Comercial__c.
 *   - Não marca nada como processado: quem já venceu entra na varredura normal
 *     do SOLPrazoTotalBatch, que continua idempotente.
 *   - allOrNone = false: um registro inválido não bloqueia os demais.
 *   - Rodar de novo é seguro: só toca Oportunidades ainda sem os dois campos.
 */
Boolean SIMULAR = true;

// ---------------------------------------------------------------- diagnóstico
List<Opportunity> semPrazo = [
  SELECT Id, Name, OwnerId, StageName, CreatedDate,
         SOL_Produto_Negocio__c, SOL_Data_Inicio_Ciclo_Comercial__c, SOL_Prazo_Total_Comercial__c
  FROM Opportunity
  WHERE RecordType.DeveloperName = 'SOL'
    AND SOL_Produto_Negocio__c IN ('Recuperação Tributária', 'ART 360')
    AND IsClosed = false
    AND (SOL_Data_Inicio_Ciclo_Comercial__c = NULL OR SOL_Prazo_Total_Comercial__c = NULL)
];
System.debug(LoggingLevel.ERROR, '=== CLICKUP-9424 · DIAGNÓSTICO ===');
System.debug(LoggingLevel.ERROR, 'Opps SOL abertas (RT/ART) sem início e/ou sem prazo: ' + semPrazo.size());

Map<Id, Opportunity> porId = new Map<Id, Opportunity>(semPrazo);

// Data de origem: SEMPRE do Lead convertido (ConvertedOpportunityId).
Map<Id, Datetime> contatoPorOpp = new Map<Id, Datetime>();
for (Lead l : [
  SELECT ConvertedOpportunityId, SOL_Data_Contato_Efetivado__c
  FROM Lead
  WHERE ConvertedOpportunityId IN :porId.keySet()
    AND IsConverted = true
    AND SOL_Data_Contato_Efetivado__c != NULL
]) {
  contatoPorOpp.put(l.ConvertedOpportunityId, l.SOL_Data_Contato_Efetivado__c);
}
System.debug(LoggingLevel.ERROR, 'Recuperáveis pelo Lead convertido: ' + contatoPorOpp.size());

List<Id> semOrigem = new List<Id>();
for (Opportunity o : semPrazo) {
  if (!contatoPorOpp.containsKey(o.Id)) {
    semOrigem.add(o.Id);
  }
}
System.debug(LoggingLevel.ERROR, 'SEM origem determinística (tratamento manual): ' + semOrigem.size() + ' -> ' + semOrigem);

// ---------------------------------------------------------------- backfill
Id bhId = SOLBusinessHoursHelper.businessHoursId();
if (bhId == null) {
  System.debug(LoggingLevel.ERROR, 'ABORTADO: calendário "Arnone Soluções - Horário Comercial" ausente/inativo.');
  return;
}

List<Opportunity> paraGravar = new List<Opportunity>();
Integer jaVencidos = 0;
for (Id oppId : contatoPorOpp.keySet()) {
  Datetime inicio = contatoPorOpp.get(oppId);
  Datetime prazo = SOLPrazoTotalService.calcularPrazoTotal(inicio);
  if (prazo <= System.now()) {
    jaVencidos++;
  }
  paraGravar.add(
    new Opportunity(
      Id = oppId,
      SOL_Data_Inicio_Ciclo_Comercial__c = inicio,
      SOL_Prazo_Total_Comercial__c = prazo
    )
  );
}
System.debug(LoggingLevel.ERROR, 'A gravar: ' + paraGravar.size() + ' (já vencidos, entrarão na varredura: ' + jaVencidos + ')');

if (SIMULAR) {
  System.debug(LoggingLevel.ERROR, 'SIMULAÇÃO — nada foi gravado. Ajuste SIMULAR = false para aplicar.');
  return;
}

Integer ok = 0;
Integer erro = 0;
if (!paraGravar.isEmpty()) {
  Database.SaveResult[] rs = Database.update(paraGravar, false);
  for (Integer i = 0; i < rs.size(); i++) {
    if (rs[i].isSuccess()) {
      ok++;
    } else {
      erro++;
      System.debug(LoggingLevel.ERROR, 'FALHA ' + paraGravar[i].Id + ': ' + rs[i].getErrors());
    }
  }
}
System.debug(LoggingLevel.ERROR, 'BACKFILL aplicado: ok=' + ok + ' erro=' + erro);
System.debug(LoggingLevel.ERROR, '=== FIM ===');
