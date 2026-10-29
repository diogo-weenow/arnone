// Revisão trabalhista — SNAPSHOT dos registros TERMINAIS (rodar ANTES e DEPOIS
// da migração dos terminais e comparar a saída; tem de ser idêntica, exceto o
// campo novo SOL_Produtos_Negocio__c preenchido).
// Somente leitura.
List<Opportunity> opps = [
  SELECT Id, StageName, SOL_Qtd_Perdas__c, SOL_Data_Encerramento__c, Amount, OwnerId, SOL_Produtos_Negocio__c
  FROM Opportunity
  WHERE RecordType.DeveloperName = 'SOL' AND IsClosed = true
  ORDER BY Id
];
Set<Id> ids = new Map<Id, Opportunity>(opps).keySet();
Decimal somaPerdas = 0; Integer comEnc = 0; Decimal somaAmt = 0; Integer comProdutoNovo = 0;
for (Opportunity o : opps) {
  somaPerdas += o.SOL_Qtd_Perdas__c == null ? 0 : o.SOL_Qtd_Perdas__c;
  if (o.SOL_Data_Encerramento__c != null) comEnc++;
  somaAmt += o.Amount == null ? 0 : o.Amount;
  if (String.isNotBlank(o.SOL_Produtos_Negocio__c)) comProdutoNovo++;
  System.debug('OPP ' + o.Id + '|' + o.StageName + '|perdas=' + o.SOL_Qtd_Perdas__c + '|enc=' + o.SOL_Data_Encerramento__c + '|amt=' + o.Amount + '|own=' + o.OwnerId);
}
Integer evTotal = [SELECT COUNT() FROM SOL_Evento_Jornada__c];
Integer evDestes = [SELECT COUNT() FROM SOL_Evento_Jornada__c WHERE SOL_Oportunidade__c IN :ids];
Map<String, Integer> tasks = new Map<String, Integer>();
for (AggregateResult ar : [SELECT Status s, COUNT(Id) c FROM Task WHERE WhatId IN :ids GROUP BY Status]) {
  tasks.put((String) ar.get('s'), (Integer) ar.get('c'));
}
System.debug('RESUMO opps=' + opps.size() + ' somaPerdas=' + somaPerdas + ' comEncerramento=' + comEnc +
  ' somaAmount=' + somaAmt + ' comProdutoNovo=' + comProdutoNovo + ' eventosTotal=' + evTotal +
  ' eventosDestes=' + evDestes + ' tasks=' + tasks);
