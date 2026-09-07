/**
 * CLICKUP-9438 — E2E REAL da PERDA REPETIDA: a mesma Oportunidade perdida DUAS
 * vezes, separadas por reabertura e partindo da MESMA etapa anterior.
 *
 * POR QUE ISOLADO NUM SCRIPT PRÓPRIO: a narrativa completa exige seis saves na
 * mesma Oportunidade, cada um disparando os Flows da jornada. Junto com o E2E
 * de dados, a transação anônima estourava o limite de 100 consultas — foi o que
 * aconteceu de fato na primeira tentativa. Cada script é uma transação.
 *
 * O QUE ESTE E2E PROVA, contra a org real e com os Flows ATIVOS:
 *   1. a Oportunidade é perdida                       -> 1 ocorrência
 *   2. reprocessar SEM nova transição (2x)            -> continua 1
 *   3. reabre
 *   4. perde de novo, da MESMA etapa anterior         -> 2 ocorrências
 *   5. reprocessar a segunda perda                    -> continua 2
 *
 * O passo 4 é o ponto: uma segunda transição REAL é ocorrência nova mesmo
 * partindo da mesma etapa. Quem separa os passos 2 e 4 é
 * `Opportunity.SOL_Qtd_Perdas__c`, carimbado pelo Flow BEFORE-SAVE
 * SOL_Marco_Perda_Oportunidade no próprio save — nenhum campo da plataforma
 * serve, porque LastStageChangeDate, LastModifiedDate e SystemModstamp têm
 * precisão de SEGUNDO e a reabertura e a segunda perda costumam cair no MESMO
 * segundo. O script imprime os dois carimbos para deixar isso visível.
 *
 * Execução, NESTA ORDEM:
 *   1. sf apex run --file scripts/apex/clickup-9438-e2e-relatorio-reatribuicoes-perdas.apex --target-org <alias>
 *   2. sf apex run --file scripts/apex/clickup-9438-e2e-perda-repetida.apex --target-org <alias>
 *   3. sf apex run --file scripts/apex/clickup-9438-e2e-conferencia-relatorio.apex --target-org <alias>
 *
 * Cria dados próprios com o prefixo E2E_9438.
 */
String TAG = 'E2E_9438-pp-' + Datetime.now().getTime();
String RT_PRODUTO = 'Recuperação Tributária';
Id rtOpp = Opportunity.SObjectType.getDescribe()
  .getRecordTypeInfosByDeveloperName()
  .get('SOL')
  .getRecordTypeId();
Date hoje = Date.today();

Integer falhas = 0;
void ok(String titulo, Boolean condicao, String detalhe) {
  System.debug(
    LoggingLevel.ERROR,
    (condicao ? '  OK      ' : '  FALHOU  ') + titulo + ' | ' + detalhe
  );
  if (!condicao) {
    falhas++;
  }
}

System.debug(LoggingLevel.ERROR, '=== CLICKUP-9438 · E2E PERDA REPETIDA (' + TAG + ') ===');

Account a = new Account(Name = 'Conta ' + TAG);
insert a;
Opportunity o = new Opportunity(
  Name = 'Op ' + TAG,
  AccountId = a.Id,
  RecordTypeId = rtOpp,
  CloseDate = hoje.addDays(60),
  StageName = 'Diagnóstico',
  SOL_Produto_Negocio__c = RT_PRODUTO,
  SOL_ECAC_Consulta_Realizada__c = true,
  SOL_ECAC_Data_Consulta__c = hoje,
  SOL_ECAC_Resultado__c = 'Valor a recuperar',
  SOL_Valor_Recuperavel__c = 1000,
  SOL_Apresentacao_Realizada__c = true,
  SOL_Data_Apresentacao__c = hoje,
  SOL_Resultado_Apresentacao__c = 'Sucesso',
  SOL_Percentual_Comissao__c = 20,
  SOL_Valor_Servico__c = 5000
);
insert o;
update new Opportunity(Id = o.Id, StageName = 'Negociação');
Id oppId = o.Id;

List<SOL_Evento_Jornada__c> ocorrencias() {
  return [
    SELECT
      Id, SOL_Sequencia__c, SOL_Etapa_Anterior__c, SOL_Chave_Idempotencia__c,
      SOL_Data_Ocorrencia__c, SOL_Vendedor__c
    FROM SOL_Evento_Jornada__c
    WHERE SOL_Oportunidade__c = :oppId
    ORDER BY SOL_Sequencia__c ASC
  ];
}
Opportunity estado() {
  return [
    SELECT StageName, SOL_Qtd_Perdas__c, LastStageChangeDate
    FROM Opportunity
    WHERE Id = :oppId
  ];
}

// -------------------------------------------------------- [1] primeira perda
update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
List<SOL_Evento_Jornada__c> apos1 = ocorrencias();
Opportunity e1 = estado();
Datetime ocorrencia1 = apos1.isEmpty() ? null : apos1[0].SOL_Data_Ocorrencia__c;
ok('[1] a perda gera UMA ocorrência', apos1.size() == 1,
  'ocorrências=' + apos1.size() + ' | contador=' + e1.SOL_Qtd_Perdas__c);

// --------------------------------- [2] reprocessar SEM transição não duplica
SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
  new List<Id>{ oppId }, new Map<Id, String>{ oppId => 'Negociação' });
SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
  new List<Id>{ oppId }, new Map<Id, String>{ oppId => 'Negociação' });
List<SOL_Evento_Jornada__c> apos2 = ocorrencias();
ok('[2] reprocessar sem nova transição NÃO duplica', apos2.size() == 1,
  'ocorrências=' + apos2.size());
ok('[2] e não reescreve a ocorrência original',
  !apos2.isEmpty() && apos2[0].SOL_Data_Ocorrencia__c == ocorrencia1,
  'antes=' + ocorrencia1 + ' depois=' + (apos2.isEmpty() ? null : apos2[0].SOL_Data_Ocorrencia__c));

// ---------------------------- [3] reabre e [4] perde de novo, da MESMA etapa
update new Opportunity(Id = oppId, StageName = 'Negociação', SOL_Motivo_Perda__c = null);
update new Opportunity(Id = oppId, StageName = 'Perdido', SOL_Motivo_Perda__c = 'Sem retorno');
List<SOL_Evento_Jornada__c> apos4 = ocorrencias();
Opportunity e2 = estado();
ok('[4] a 2ª perda REAL, da mesma etapa, é ocorrência NOVA', apos4.size() == 2,
  'ocorrências=' + apos4.size() + ' | contador=' + e2.SOL_Qtd_Perdas__c);
System.debug(LoggingLevel.ERROR, '[4]   LastStageChangeDate: 1ª perda=' + e1.LastStageChangeDate.getTime()
  + ' | 2ª perda=' + e2.LastStageChangeDate.getTime()
  + (e1.LastStageChangeDate == e2.LastStageChangeDate
      ? '  <-- MESMO carimbo: uma chave por timestamp teria COLAPSADO as duas transições'
      : '  (carimbos diferentes nesta execução; a precisão de SEGUNDO continua sendo o motivo do contador)'));

// ------------------------------------ [5] reprocessar a segunda perda também
SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
  new List<Id>{ oppId }, new Map<Id, String>{ oppId => 'Negociação' });
List<SOL_Evento_Jornada__c> apos5 = ocorrencias();
ok('[5] reprocessar a 2ª perda NÃO duplica', apos5.size() == 2, 'ocorrências=' + apos5.size());

if (apos5.size() == 2) {
  ok('[5] as duas saíram da MESMA etapa anterior',
    apos5[0].SOL_Etapa_Anterior__c == 'Negociação' && apos5[1].SOL_Etapa_Anterior__c == 'Negociação',
    apos5[0].SOL_Etapa_Anterior__c + ' / ' + apos5[1].SOL_Etapa_Anterior__c);
  ok('[5] sequências 1 e 2',
    apos5[0].SOL_Sequencia__c == 1 && apos5[1].SOL_Sequencia__c == 2,
    apos5[0].SOL_Sequencia__c + ' / ' + apos5[1].SOL_Sequencia__c);
  ok('[5] chaves distintas',
    apos5[0].SOL_Chave_Idempotencia__c != apos5[1].SOL_Chave_Idempotencia__c,
    apos5[0].SOL_Chave_Idempotencia__c + ' | ' + apos5[1].SOL_Chave_Idempotencia__c);
  ok('[5] etapa anterior NUNCA é "Perdido"',
    apos5[0].SOL_Etapa_Anterior__c != 'Perdido' && apos5[1].SOL_Etapa_Anterior__c != 'Perdido',
    apos5[0].SOL_Etapa_Anterior__c + ' / ' + apos5[1].SOL_Etapa_Anterior__c);
}

System.debug(LoggingLevel.ERROR, '=== Oportunidade do E2E: ' + oppId + ' ===');
System.debug(LoggingLevel.ERROR, '=== RESULTADO: ' + (falhas == 0 ? 'TODAS AS VERIFICAÇÕES PASSARAM' : falhas + ' VERIFICAÇÃO(ÕES) FALHARAM') + ' ===');
