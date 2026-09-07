/**
 * CLICKUP-9438 — E2E de CONFERÊNCIA: os dois relatórios EXECUTADOS de verdade,
 * confrontados linha a linha com SOQL independente.
 *
 * POR QUE É UM SCRIPT SEPARADO: o motor de relatórios só enxerga dado
 * COMMITADO. Dentro da mesma transação que cria as ocorrências — seja o E2E de
 * dados, seja uma classe de teste — o relatório devolveria a org, não o
 * cenário. Rode este script DEPOIS de
 * `clickup-9438-e2e-relatorio-reatribuicoes-perdas.apex`.
 *
 * O que é verificado, por EXECUÇÃO e não por inspeção de XML:
 *   [A] Os dois relatórios rodam (nada de matriz sem detalhe que implanta e
 *       quebra em runtime) e usam o report type do objeto de eventos.
 *   [B] O total de linhas do relatório bate com COUNT() por SOQL.
 *   [C] A quantidade POR MOTIVO bate com o GROUP BY por SOQL.
 *   [D] O "% do total" é coerente com a quantidade e a soma fecha em 100%.
 *   [E] O filtro de período está declarado sobre SOL_Data_Ocorrencia__c, e o
 *       recorte que ele produz bate com o mesmo recorte feito por SOQL.
 *   [F] O relatório de perdas segmenta pela ETAPA ANTERIOR real e nunca traz
 *       "Perdido" como etapa de origem.
 *
 * Execução:
 *   sf apex run --file scripts/apex/clickup-9438-e2e-conferencia-relatorio.apex --target-org <alias>
 */
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

System.debug(LoggingLevel.ERROR, '=== CLICKUP-9438 · E2E_9438 CONFERÊNCIA DOS RELATÓRIOS ===');

Map<String, Id> relatorios = new Map<String, Id>();
for (Report r : [
  SELECT Id, DeveloperName, Name
  FROM Report
  WHERE
    DeveloperName IN (
      'SOL_Reatribuicoes_e_Perdas',
      'SOL_Perdas_Oportunidade_Etapa_Anterior'
    )
]) {
  relatorios.put(r.DeveloperName, r.Id);
  System.debug(LoggingLevel.ERROR, 'relatório: ' + r.DeveloperName + ' = ' + r.Id + ' (' + r.Name + ')');
}
ok('[A] os dois relatórios existem na pasta Arnone_Comercial', relatorios.size() == 2,
  'encontrados=' + relatorios.size());

// =========================================================== RELATÓRIO 1
Id idGeral = relatorios.get('SOL_Reatribuicoes_e_Perdas');
if (idGeral != null) {
  Reports.ReportDescribeResult descreve = Reports.ReportManager.describeReport(idGeral);
  Reports.ReportMetadata meta = descreve.getReportMetadata();
  System.debug(LoggingLevel.ERROR, '[A] formato=' + meta.getReportFormat()
    + ' agrupamento=' + meta.getGroupingsDown()[0].getName()
    + ' agregados=' + meta.getAggregates()
    + ' detalhe=' + meta.getDetailColumns());
  ok('[A] agrupado por MOTIVO', meta.getGroupingsDown()[0].getName() == 'SOL_Evento_Jornada__c.SOL_Motivo__c',
    meta.getGroupingsDown()[0].getName());

  // A ORDEM dos agregados no factMap é a de meta.getAggregates(), e NÃO é
  // "RowCount primeiro": aqui a fórmula "% do total" vem antes. Ler por índice
  // fixo daria número trocado sem erro nenhum aparecer.
  Integer iQtd = meta.getAggregates().indexOf('RowCount');
  Integer iPct = meta.getAggregates().indexOf('FORMULA1');
  ok('[A] agregados de quantidade e de "% do total" presentes', iQtd >= 0 && iPct >= 0,
    'RowCount=' + iQtd + ' FORMULA1=' + iPct);
  ok('[A] tem coluna de detalhe (relatório sem detalhe implanta e não roda)',
    meta.getDetailColumns() != null && !meta.getDetailColumns().isEmpty(),
    'colunas=' + (meta.getDetailColumns() == null ? 0 : meta.getDetailColumns().size()));

  Reports.StandardDateFilter periodo = meta.getStandardDateFilter();
  System.debug(LoggingLevel.ERROR, '[E] filtro de período: coluna=' + (periodo == null ? 'AUSENTE' : periodo.getColumn())
    + ' duração=' + (periodo == null ? '-' : periodo.getDurationValue())
    + ' de=' + (periodo == null ? '-' : periodo.getStartDate())
    + ' até=' + (periodo == null ? '-' : periodo.getEndDate()));
  ok('[E] período declarado sobre a DATA DA OCORRÊNCIA',
    periodo != null && periodo.getColumn() == 'SOL_Evento_Jornada__c.SOL_Data_Ocorrencia__c',
    periodo == null ? 'sem filtro de período' : periodo.getColumn());

  Reports.ReportResults resultado = Reports.ReportManager.runReport(idGeral, true);
  Reports.ReportFactWithDetails geral = (Reports.ReportFactWithDetails) resultado.getFactMap()
    .get('T!T');
  Integer totalRelatorio = Integer.valueOf(geral.getAggregates()[iQtd].getValue());

  // Mesmo recorte, por SOQL independente: filtro travado de Record Type e o
  // período que o próprio relatório declarou.
  Date de = periodo == null ? null : Date.valueOf(periodo.getStartDate());
  Date ate = periodo == null ? null : Date.valueOf(periodo.getEndDate());
  Integer totalSoql = de == null
    ? [SELECT COUNT() FROM SOL_Evento_Jornada__c WHERE SOL_Record_Type_Origem__c = 'SOL']
    : [
        SELECT COUNT()
        FROM SOL_Evento_Jornada__c
        WHERE
          SOL_Record_Type_Origem__c = 'SOL'
          AND DAY_ONLY(convertTimezone(SOL_Data_Ocorrencia__c)) >= :de
          AND DAY_ONLY(convertTimezone(SOL_Data_Ocorrencia__c)) <= :ate
      ];
  ok('[B] total do relatório == COUNT() por SOQL', totalRelatorio == totalSoql,
    'relatório=' + totalRelatorio + ' soql=' + totalSoql);

  Map<String, Integer> soqlPorMotivo = new Map<String, Integer>();
  for (AggregateResult ar : de == null
    ? [
        SELECT SOL_Motivo__c motivo, COUNT(Id) qtd
        FROM SOL_Evento_Jornada__c
        WHERE SOL_Record_Type_Origem__c = 'SOL'
        GROUP BY SOL_Motivo__c
      ]
    : [
        SELECT SOL_Motivo__c motivo, COUNT(Id) qtd
        FROM SOL_Evento_Jornada__c
        WHERE
          SOL_Record_Type_Origem__c = 'SOL'
          AND DAY_ONLY(convertTimezone(SOL_Data_Ocorrencia__c)) >= :de
          AND DAY_ONLY(convertTimezone(SOL_Data_Ocorrencia__c)) <= :ate
        GROUP BY SOL_Motivo__c
      ]) {
    soqlPorMotivo.put((String) ar.get('motivo'), (Integer) ar.get('qtd'));
  }

  Decimal somaPct = 0;
  Integer somaQtd = 0;
  Integer grupos = 0;
  for (Reports.GroupingValue g : resultado.getGroupingsDown().getGroupings()) {
    grupos++;
    Reports.ReportFactWithDetails linha = (Reports.ReportFactWithDetails) resultado.getFactMap()
      .get(g.getKey() + '!T');
    Integer qtd = Integer.valueOf(linha.getAggregates()[iQtd].getValue());
    Object pctBruto = linha.getAggregates()[iPct].getValue();
    // Medido na org, não suposto: a fórmula
    // RowCount/PARENTGROUPVAL(RowCount, GRAND_SUMMARY) com saída "percent" já
    // devolve o valor EM PONTOS PERCENTUAIS (33.3), não em fração (0.333) — e
    // arredondado pelo `scale` do relatório, que é 1 casa. Multiplicar por 100
    // aqui daria 3330% sem erro nenhum aparecer.
    Decimal pct = pctBruto == null
      ? null
      : Decimal.valueOf(String.valueOf(pctBruto)).setScale(2);
    somaQtd += qtd;
    if (pct != null) {
      somaPct += pct;
    }
    String motivo = g.getLabel();
    Integer esperado = soqlPorMotivo.containsKey(motivo) ? soqlPorMotivo.get(motivo) : -1;
    System.debug(LoggingLevel.ERROR, '[C]   ' + motivo + ': relatório=' + qtd
      + ' soql=' + esperado + ' | % do total=' + pct);
    ok('[C] quantidade do motivo "' + motivo + '" confere com SOQL', qtd == esperado,
      'relatório=' + qtd + ' soql=' + esperado);
    if (pct != null && totalRelatorio > 0) {
      Decimal pctEsperado = (Decimal.valueOf(qtd) / totalRelatorio * 100).setScale(2);
      ok('[D] "% do total" de "' + motivo + '" coerente com a quantidade',
        Math.abs(pct - pctEsperado) <= 0.5, 'relatório=' + pct + ' calculado=' + pctEsperado);
    }
  }
  ok('[C] a soma dos motivos é o total geral', somaQtd == totalRelatorio,
    'soma=' + somaQtd + ' total=' + totalRelatorio);
  ok('[C] todos os motivos do SOQL aparecem no relatório', grupos == soqlPorMotivo.size(),
    'grupos=' + grupos + ' motivos no soql=' + soqlPorMotivo.size());
  ok('[D] os percentuais somam 100% (salvo arredondamento)', Math.abs(somaPct - 100) <= 1,
    'soma=' + somaPct);
}

// =========================================================== RELATÓRIO 2
Id idEtapa = relatorios.get('SOL_Perdas_Oportunidade_Etapa_Anterior');
if (idEtapa != null) {
  Reports.ReportDescribeResult d2 = Reports.ReportManager.describeReport(idEtapa);
  Reports.ReportMetadata m2 = d2.getReportMetadata();
  ok('[F] agrupado pela ETAPA ANTERIOR',
    m2.getGroupingsDown()[0].getName() == 'SOL_Evento_Jornada__c.SOL_Etapa_Anterior__c',
    m2.getGroupingsDown()[0].getName());
  ok('[F] tem coluna de detalhe', m2.getDetailColumns() != null && !m2.getDetailColumns().isEmpty(),
    'colunas=' + (m2.getDetailColumns() == null ? 0 : m2.getDetailColumns().size()));
  Reports.StandardDateFilter p2 = m2.getStandardDateFilter();
  ok('[F] período sobre a data da ocorrência',
    p2 != null && p2.getColumn() == 'SOL_Evento_Jornada__c.SOL_Data_Ocorrencia__c',
    p2 == null ? 'sem filtro de período' : p2.getColumn());

  Integer iQtd2 = m2.getAggregates().indexOf('RowCount');
  Reports.ReportResults r2 = Reports.ReportManager.runReport(idEtapa, true);
  Reports.ReportFactWithDetails t2 = (Reports.ReportFactWithDetails) r2.getFactMap().get('T!T');
  Integer totalPerdas = Integer.valueOf(t2.getAggregates()[iQtd2].getValue());

  Date de2 = p2 == null ? null : Date.valueOf(p2.getStartDate());
  Date ate2 = p2 == null ? null : Date.valueOf(p2.getEndDate());
  Map<String, Integer> soqlPorEtapa = new Map<String, Integer>();
  Integer totalSoql2 = 0;
  for (AggregateResult ar : de2 == null
    ? [
        SELECT SOL_Etapa_Anterior__c etapa, COUNT(Id) qtd
        FROM SOL_Evento_Jornada__c
        WHERE
          SOL_Record_Type_Origem__c = 'SOL'
          AND SOL_Motivo__c = 'Oportunidade perdida'
        GROUP BY SOL_Etapa_Anterior__c
      ]
    : [
        SELECT SOL_Etapa_Anterior__c etapa, COUNT(Id) qtd
        FROM SOL_Evento_Jornada__c
        WHERE
          SOL_Record_Type_Origem__c = 'SOL'
          AND SOL_Motivo__c = 'Oportunidade perdida'
          AND DAY_ONLY(convertTimezone(SOL_Data_Ocorrencia__c)) >= :de2
          AND DAY_ONLY(convertTimezone(SOL_Data_Ocorrencia__c)) <= :ate2
        GROUP BY SOL_Etapa_Anterior__c
      ]) {
    soqlPorEtapa.put((String) ar.get('etapa'), (Integer) ar.get('qtd'));
    totalSoql2 += (Integer) ar.get('qtd');
  }
  ok('[F] total de perdas do relatório == SOQL', totalPerdas == totalSoql2,
    'relatório=' + totalPerdas + ' soql=' + totalSoql2);

  for (Reports.GroupingValue g : r2.getGroupingsDown().getGroupings()) {
    Reports.ReportFactWithDetails linha = (Reports.ReportFactWithDetails) r2.getFactMap()
      .get(g.getKey() + '!T');
    Integer qtd = Integer.valueOf(linha.getAggregates()[iQtd2].getValue());
    String etapa = g.getLabel();
    Integer esperado = soqlPorEtapa.containsKey(etapa) ? soqlPorEtapa.get(etapa) : -1;
    System.debug(LoggingLevel.ERROR, '[F]   etapa anterior "' + etapa + '": relatório=' + qtd + ' soql=' + esperado);
    ok('[F] quantidade da etapa "' + etapa + '" confere com SOQL', qtd == esperado,
      'relatório=' + qtd + ' soql=' + esperado);
    ok('[F] a etapa de origem NUNCA é "Perdido"', etapa != 'Perdido', etapa);
  }
}

// ============================ CONTROLE: NÃO SE CONTA TROCA DE OWNER
Integer trocasDeOwner = [
  SELECT COUNT()
  FROM LeadHistory
  WHERE Field = 'Owner'
];
Integer reatribuicoesReais = [
  SELECT COUNT()
  FROM SOL_Evento_Jornada__c
  WHERE SOL_Tipo_Evento__c = 'Reatribuição'
];
System.debug(LoggingLevel.ERROR, '[G] CONTROLE — trocas de Owner no LeadHistory = ' + trocasDeOwner
  + ' | reatribuições registradas como OCORRÊNCIA = ' + reatribuicoesReais
  + '  → os dois números não são o mesmo, e é por isso que o relatório não conta Field History.');

System.debug(LoggingLevel.ERROR, '=== RESULTADO: ' + (falhas == 0 ? 'TODAS AS VERIFICAÇÕES PASSARAM' : falhas + ' VERIFICAÇÃO(ÕES) FALHARAM') + ' ===');
