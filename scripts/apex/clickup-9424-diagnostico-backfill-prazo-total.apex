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
 *   - NÃO sobrescreve em silêncio: se só um dos dois campos já estiver
 *     preenchido, valida a consistência contra a régua determinística e LISTA
 *     as divergências para tratamento manual — grava só o campo que falta
 *     quando o que já existe bate com a régua.
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

// REGRA (revisão do PR #15): quando SÓ UM dos dois campos de prazo já está
// preenchido, NADA é sobrescrito em silêncio. O script valida a consistência
// contra a régua determinística (Lead convertido + 30 dias úteis) e LISTA as
// divergências para tratamento manual. Só grava:
//   (a) os dois campos, quando AMBOS estão vazios; ou
//   (b) o campo que falta, quando o que já existe BATE com a régua.
List<Opportunity> paraGravar = new List<Opportunity>();
List<String> divergencias = new List<String>();
Integer jaVencidos = 0;
Integer completados = 0;
Integer consistentesSemAcao = 0;

for (Id oppId : contatoPorOpp.keySet()) {
  Opportunity atual = porId.get(oppId);
  Datetime inicioRegua = contatoPorOpp.get(oppId);
  Datetime prazoRegua = SOLPrazoTotalService.calcularPrazoTotal(inicioRegua);

  Datetime inicioAtual = atual.SOL_Data_Inicio_Ciclo_Comercial__c;
  Datetime prazoAtual = atual.SOL_Prazo_Total_Comercial__c;

  Boolean inicioDiverge = inicioAtual != null && inicioAtual != inicioRegua;
  Boolean prazoDiverge = prazoAtual != null && prazoAtual != prazoRegua;

  if (inicioDiverge || prazoDiverge) {
    divergencias.add(
      oppId +
        ' (' + atual.Name + '): ' +
        (inicioDiverge
          ? 'início gravado ' + inicioAtual + ' ≠ régua ' + inicioRegua + '; '
          : '') +
        (prazoDiverge
          ? 'prazo gravado ' + prazoAtual + ' ≠ régua ' + prazoRegua
          : '')
    );
    continue; // NÃO sobrescreve
  }

  if (inicioAtual == null && prazoAtual == null) {
    // Caso (a): ambos vazios — grava os dois.
    paraGravar.add(
      new Opportunity(
        Id = oppId,
        SOL_Data_Inicio_Ciclo_Comercial__c = inicioRegua,
        SOL_Prazo_Total_Comercial__c = prazoRegua
      )
    );
    if (prazoRegua <= System.now()) {
      jaVencidos++;
    }
  } else if (inicioAtual != null && prazoAtual == null) {
    // Caso (b): início consistente, só falta o limite.
    paraGravar.add(
      new Opportunity(Id = oppId, SOL_Prazo_Total_Comercial__c = prazoRegua)
    );
    completados++;
    if (prazoRegua <= System.now()) {
      jaVencidos++;
    }
  } else if (inicioAtual == null && prazoAtual != null) {
    // Prazo preenchido sem início: estado inconsistente mesmo "batendo" — não
    // dá para confirmar a origem. Lista para tratamento manual.
    divergencias.add(
      oppId + ' (' + atual.Name + '): prazo preenchido sem data de início de ciclo.'
    );
  } else {
    consistentesSemAcao++;
  }
}

System.debug(LoggingLevel.ERROR, 'A gravar: ' + paraGravar.size()
  + ' (ambos vazios + apenas-limite=' + completados
  + ' | já vencidos, entrarão na varredura: ' + jaVencidos
  + ' | já consistentes, sem ação: ' + consistentesSemAcao + ')');
System.debug(LoggingLevel.ERROR, 'DIVERGÊNCIAS (tratamento manual, NÃO sobrescritas): ' + divergencias.size());
for (String d : divergencias) {
  System.debug(LoggingLevel.ERROR, '  - ' + d);
}

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
