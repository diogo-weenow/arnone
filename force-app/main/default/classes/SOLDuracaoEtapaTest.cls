/**
 * CLICKUP-9439 / CLICKUP-9429 (absorvido) — testes da duração por etapa.
 *
 * O que se prova aqui é o que só existe neste card: a CONTAGEM em dias úteis
 * entre dois marcos, a POLÍTICA quando ela não pode ser feita, e a promessa de
 * que nada disso derruba operação comercial.
 *
 * RELÓGIO E CALENDÁRIO — todos os cenários ancoram em datas REAIS do calendário
 * comercial da org (seg-qui 08:00-18:00, sex 08:00-17:00, America/Sao_Paulo),
 * na semana de 31/08/2026 (segunda) a 06/09/2026 (domingo), com a sexta
 * anterior em 28/08. Sem grade fixa, o resultado dependeria do dia em que a
 * suíte roda — um teste que passa na terça e falha no sábado não prova nada.
 *
 * SOBRE FERIADO: a org NÃO tem nenhum registro de Holiday, e a associação
 * Holiday-BusinessHours não é gravável por API — logo o cenário de feriado não
 * é sintetizável em teste. O método `feriadoSegueAMesmaReguaDoFimDeSemana`
 * VERIFICA essa condição em vez de presumi-la, e explica por que a cobertura do
 * fim de semana é a mesma cobertura do feriado: `ehDiaUtil` decide por
 * `aberturaDoDia`, que é uma única chamada a `BusinessHours.nextStartDate` —
 * não existe ramo separado para feriado. A limitação está declarada no PR.
 */
@IsTest
private class SOLDuracaoEtapaTest {
  private static final String RT_SOL = 'SOL';
  private static final String PRODUTO_RT = 'Recuperação Tributária';
  private static final String PRODUTO_ART = 'ART 360';
  private static final String CNPJ = '11222333000181';

  // Grade fixa do calendário comercial (datas passadas, de propósito).
  private static final Date SEXTA_ANTERIOR = Date.newInstance(2026, 8, 28);
  private static final Date SABADO_ANTERIOR = Date.newInstance(2026, 8, 29);
  private static final Date DOMINGO_ANTERIOR = Date.newInstance(2026, 8, 30);
  private static final Date SEGUNDA = Date.newInstance(2026, 8, 31);
  private static final Date TERCA = Date.newInstance(2026, 9, 1);
  private static final Date QUARTA = Date.newInstance(2026, 9, 2);
  private static final Date QUINTA = Date.newInstance(2026, 9, 3);
  private static final Date SEXTA = Date.newInstance(2026, 9, 4);
  private static final Date SABADO = Date.newInstance(2026, 9, 5);
  private static final Date SEGUNDA_SEGUINTE = Date.newInstance(2026, 9, 7);

  private static Integer seq = 0;

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ============================================================== helpers

  private static String rnd() {
    seq++;
    return seq + 'x' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
  }

  /** Instante correspondente a `hora:minuto` em São Paulo (UTC-3, sem DST). */
  private static Datetime emSaoPaulo(Date d, Integer hora, Integer minuto) {
    Datetime meiaNoiteSP = Datetime.newInstanceGmt(
      d,
      Time.newInstance(3, 0, 0, 0)
    );
    return meiaNoiteSP.addMinutes(hora * 60 + minuto);
  }

  private static Datetime as10(Date d) {
    return emSaoPaulo(d, 10, 0);
  }

  private static Id bh() {
    return SOLBusinessHoursHelper.businessHoursId();
  }

  private static Id rtLead() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(RT_SOL)
      .getRecordTypeId();
  }

  private static Id rtOpp() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(RT_SOL)
      .getRecordTypeId();
  }

  /**
   * Lead SOL inserido e com o dono reposto. A distribuição do CLICKUP-9394 roda
   * no after-save e, sem roster ativo nesta transação, estaciona o Lead na fila
   * — o dono precisa voltar para o usuário para que os cenários de conversão e
   * de edição funcionem, exatamente como as fixtures dos cards anteriores.
   */
  private static Lead novoLead(String produto) {
    Lead l = new Lead(
      RecordTypeId = rtLead(),
      FirstName = 'Duracao',
      LastName = 'Lead ' + rnd(),
      Company = 'Empresa ' + rnd(),
      Email = 'dur.' + rnd().left(8) + '@exemplo.invalid',
      CNPJ__c = CNPJ,
      SOL_Produto_Interesse__c = produto
    );
    Database.DMLOptions opc = new Database.DMLOptions();
    opc.duplicateRuleHeader.allowSave = true;
    Database.insert(l, opc);
    // SOL_Data_Distribuicao__c é ZERADA de propósito. A distribuição do
    // CLICKUP-9394 roda no after-save e carimba o campo com o instante REAL, que
    // não pertence à grade fixa de 2026 usada aqui — deixá-lo carimbado faria a
    // etapa 1 nascer com destino anterior à origem em todo cenário que não a
    // controla. Cada teste que precisa da etapa 1 grava a data explicitamente.
    update new Lead(
      Id = l.Id,
      OwnerId = UserInfo.getUserId(),
      SOL_Data_Distribuicao__c = null
    );
    return l;
  }

  private static Lead lead(Id leadId) {
    return [
      SELECT
        Id,
        IsConverted,
        ConvertedOpportunityId,
        SOL_Data_Distribuicao__c,
        SOL_Data_Primeira_Ligacao__c,
        SOL_Data_Contato_Efetivado__c,
        SOL_Data_Reuniao_Realizada__c,
        SOL_Data_Recebimento_Procuracao__c,
        SOL_Data_Reuniao_Procuracao__c,
        SOL_Dias_Primeira_Ligacao__c,
        SOL_Dias_Contato_Efetivado__c,
        SOL_Dias_Reuniao_Procuracao__c,
        SOL_Duracao_Pendente__c,
        SOL_Duracao_Pendencia_Motivo__c,
        SOL_Duracao_Pendencia_Detalhe__c
      FROM Lead
      WHERE Id = :leadId
    ];
  }

  private static Opportunity opp(Id oppId) {
    return [
      SELECT
        Id,
        StageName,
        SOL_Produto_Negocio__c,
        SOL_Data_Primeira_Ligacao__c,
        SOL_Data_Inicio_Ciclo_Comercial__c,
        SOL_Data_Reuniao_Procuracao__c,
        SOL_Data_Solicitacao_Calculo__c,
        SOL_Data_Recebimento_Calculo__c,
        SOL_Data_Reuniao_Final__c,
        SOL_Data_Encerramento__c,
        SOL_Dias_Primeira_Ligacao__c,
        SOL_Dias_Contato_Efetivado__c,
        SOL_Dias_Reuniao_Procuracao__c,
        SOL_Dias_Calculo_Juridico__c,
        SOL_Dias_Reuniao_Final__c,
        SOL_Dias_Fechamento__c,
        SOL_Duracao_Pendente__c,
        SOL_Duracao_Pendencia_Motivo__c,
        SOL_Duracao_Pendencia_Detalhe__c
      FROM Opportunity
      WHERE Id = :oppId
    ];
  }

  /** Oportunidade SOL na etapa Diagnóstico, com os termos financeiros prontos. */
  private static Opportunity novaOpp(String produto) {
    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd(),
      AccountId = a.Id,
      RecordTypeId = rtOpp(),
      CloseDate = Date.today().addDays(60),
      StageName = 'Diagnóstico',
      SOL_Produto_Negocio__c = produto,
      SOL_ECAC_Consulta_Realizada__c = true,
      SOL_ECAC_Data_Consulta__c = Date.today(),
      SOL_ECAC_Resultado__c = 'Valor a recuperar',
      SOL_Valor_Recuperavel__c = 1000,
      SOL_Apresentacao_Realizada__c = true,
      SOL_Data_Apresentacao__c = Date.today(),
      SOL_Resultado_Apresentacao__c = 'Sucesso',
      SOL_Percentual_Comissao__c = 20,
      SOL_Valor_Servico__c = 5000
    );
    insert o;
    return o;
  }

  private static void recalcularLead(Id leadId) {
    SOLDuracaoEtapaService.recalcularLeads(new List<Id>{ leadId });
  }

  private static void recalcularOpp(Id oppId) {
    SOLDuracaoEtapaService.recalcularOportunidades(new List<Id>{ oppId });
  }

  // ====================================================== a régua de dias

  @IsTest
  static void mesmoDiaUtilContaZero() {
    Assert.areEqual(
      0,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEGUNDA, SEGUNDA),
      'Etapa aberta e fechada no mesmo dia útil dura zero dias úteis — e zero é um valor, não vazio.'
    );
  }

  @IsTest
  static void diasUteisConsecutivosNaSemana() {
    Assert.areEqual(
      1,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEGUNDA, TERCA),
      'De segunda para terça há exatamente um dia útil no intervalo (segunda, terça].'
    );
    Assert.areEqual(
      4,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEGUNDA, SEXTA),
      'De segunda para sexta: terça, quarta, quinta e sexta.'
    );
  }

  @IsTest
  static void fimDeSemanaNaoEntraNaContagem() {
    Assert.areEqual(
      1,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEXTA_ANTERIOR, SEGUNDA),
      'Sábado e domingo não têm expediente: da sexta para a segunda conta só a segunda.'
    );
  }

  @IsTest
  static void sextaAtravessandoOFimDeSemana() {
    Assert.areEqual(
      1,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEXTA, SEGUNDA_SEGUINTE),
      'A sexta é origem e não conta; o fim de semana não tem expediente; sobra a segunda.'
    );
    Assert.areEqual(
      2,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEXTA_ANTERIOR, TERCA),
      'Da sexta anterior até terça: segunda e terça.'
    );
  }

  @IsTest
  static void destinoNoFimDeSemanaNaoConta() {
    Assert.areEqual(
      0,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEXTA_ANTERIOR, SABADO_ANTERIOR),
      'Sábado não tem expediente: o intervalo (sexta, sábado] não tem nenhum dia útil.'
    );
    Assert.areEqual(
      0,
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEXTA_ANTERIOR, DOMINGO_ANTERIOR),
      'Nem sábado nem domingo entram na contagem.'
    );
  }

  @IsTest
  static void destinoAnteriorAOrigemLancaIntervaloInvalido() {
    Boolean lancou = false;
    try {
      SOLBusinessHoursHelper.diasUteisEntre(bh(), SEXTA, SEGUNDA);
    } catch (SOLBusinessHoursHelper.IntervaloInvalidoException e) {
      lancou = true;
    }
    Assert.isTrue(
      lancou,
      'Destino anterior à origem é DADO inválido: a régua lança em vez de devolver número negativo.'
    );
  }

  @IsTest
  static void semCalendarioLancaCalendarioIndisponivel() {
    Boolean lancou = false;
    try {
      SOLBusinessHoursHelper.diasUteisEntre(null, SEGUNDA, TERCA);
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      lancou = true;
    }
    Assert.isTrue(
      lancou,
      'Sem calendário a régua lança a exceção TRANSITÓRIA — nunca devolve zero disfarçado de resposta.'
    );
  }

  @IsTest
  static void diasUteisNoIntervaloTrazSoDiasComExpediente() {
    Set<Date> uteis = SOLBusinessHoursHelper.diasUteisNoIntervalo(
      bh(),
      SEXTA_ANTERIOR,
      SEGUNDA_SEGUINTE
    );
    Assert.isTrue(uteis.contains(SEXTA_ANTERIOR), 'Sexta 28/08 é dia útil.');
    Assert.isFalse(uteis.contains(SABADO_ANTERIOR), 'Sábado 29/08 não é dia útil.');
    Assert.isFalse(uteis.contains(DOMINGO_ANTERIOR), 'Domingo 30/08 não é dia útil.');
    Assert.isTrue(uteis.contains(SEGUNDA), 'Segunda 31/08 é dia útil.');
    Assert.isFalse(uteis.contains(SABADO), 'Sábado 05/09 não é dia útil.');
    Assert.areEqual(
      7,
      uteis.size(),
      'De 28/08 a 07/09 há 7 dias com expediente: 28, 31, 01, 02, 03, 04 e 07.'
    );
  }

  /**
   * FERIADO — o cenário não é sintetizável, e este método VERIFICA isso em vez
   * de presumir. A org não tem Holiday cadastrado, e a associação
   * Holiday-BusinessHours não é gravável por API. Se um dia houver feriado
   * configurado, o teste passa a exercitá-lo de verdade, sem precisar de ajuste.
   *
   * O que já está provado sem feriado: `ehDiaUtil` decide unicamente por
   * `aberturaDoDia`, que é uma chamada a `BusinessHours.nextStartDate`. Um
   * feriado configurado faz essa chamada pular o dia pelo MESMO caminho que já
   * pula sábado e domingo — não existe ramo separado. A cobertura fim de semana
   * é a cobertura do mecanismo.
   */
  @IsTest
  static void feriadoSegueAMesmaReguaDoFimDeSemana() {
    List<Holiday> feriados = [
      SELECT Id, ActivityDate
      FROM Holiday
      WHERE ActivityDate != NULL
      LIMIT 50
    ];
    Date feriadoEmDiaDeSemana = null;
    for (Holiday h : feriados) {
      Datetime d = Datetime.newInstanceGmt(
        h.ActivityDate,
        Time.newInstance(12, 0, 0, 0)
      );
      String diaDaSemana = d.formatGmt('EEE');
      if (diaDaSemana != 'Sat' && diaDaSemana != 'Sun') {
        feriadoEmDiaDeSemana = h.ActivityDate;
        break;
      }
    }

    if (feriadoEmDiaDeSemana != null) {
      Assert.isFalse(
        SOLBusinessHoursHelper.ehDiaUtil(bh(), feriadoEmDiaDeSemana),
        'Feriado do calendário em dia de semana não pode contar como dia útil: ' +
        feriadoEmDiaDeSemana
      );
      return;
    }

    Assert.areEqual(
      0,
      feriados.size(),
      'A org não tem feriado cadastrado — o cenário não é sintetizável e a limitação está declarada no PR. ' +
      'Se esta asserção falhar, é porque passou a existir feriado e o ramo de cima deveria tê-lo exercitado.'
    );
    Assert.isFalse(
      SOLBusinessHoursHelper.ehDiaUtil(bh(), SABADO_ANTERIOR),
      'O mecanismo que excluiria o feriado é o mesmo que exclui o sábado: aberturaDoDia devolve null.'
    );
  }

  // ============================================== etapas 1 a 3, no Lead

  @IsTest
  static void etapa1DaDistribuicaoAtePrimeiraLigacao() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA)
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.areEqual(
      2,
      depois.SOL_Dias_Primeira_Ligacao__c,
      'De segunda a quarta há dois dias úteis no intervalo (segunda, quarta].'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'Etapa calculada não deixa pendência.'
    );
  }

  @IsTest
  static void etapa2DaPrimeiraLigacaoAteContatoEfetivado() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Primeira_Ligacao__c = as10(SEXTA_ANTERIOR),
      SOL_Data_Contato_Efetivado__c = as10(TERCA)
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Assert.areEqual(
      2,
      lead(l.Id).SOL_Dias_Contato_Efetivado__c,
      'Da sexta ao contato efetivado na terça: segunda e terça, sem o fim de semana.'
    );
  }

  @IsTest
  static void etapa3UsaOUltimoDosDoisMarcos() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Contato_Efetivado__c = as10(SEGUNDA),
      SOL_Data_Reuniao_Realizada__c = as10(QUARTA),
      SOL_Data_Recebimento_Procuracao__c = SEXTA
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.areEqual(
      SEXTA,
      depois.SOL_Data_Reuniao_Procuracao__c,
      'O marco da etapa 3 é o ÚLTIMO dos dois: a procuração (sexta) veio depois da reunião (quarta).'
    );
    Assert.areEqual(
      4,
      depois.SOL_Dias_Reuniao_Procuracao__c,
      'De segunda a sexta: terça, quarta, quinta e sexta.'
    );
  }

  @IsTest
  static void etapa3ComUmMarcoSoFicaVaziaESemPendencia() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Contato_Efetivado__c = as10(SEGUNDA),
      SOL_Data_Reuniao_Realizada__c = as10(QUARTA)
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.isNull(
      depois.SOL_Data_Reuniao_Procuracao__c,
      'Com um marco só a etapa 3 não terminou: o consolidado NÃO pode receber o marco isolado.'
    );
    Assert.isNull(
      depois.SOL_Dias_Reuniao_Procuracao__c,
      'Etapa não concluída fica VAZIA — nunca zero.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'Falta de marco NÃO é pendência: é etapa que ainda não aconteceu.'
    );
  }

  /**
   * A reunião é DateTime e a procuração é Date. Às 23:30 de São Paulo o dia em
   * GMT já virou: comparar sem normalizar escolheria a reunião (dia seguinte em
   * GMT) como o "último" marco, quando na verdade os dois caíram na sexta.
   */
  @IsTest
  static void marcoDaEtapa3NormalizaOFusoAntesDeComparar() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Contato_Efetivado__c = as10(SEGUNDA),
      SOL_Data_Reuniao_Realizada__c = emSaoPaulo(SEXTA, 23, 30),
      SOL_Data_Recebimento_Procuracao__c = SEXTA
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.areEqual(
      SEXTA,
      depois.SOL_Data_Reuniao_Procuracao__c,
      'A reunião às 23:30 de São Paulo continua sendo sexta — em GMT já seria sábado, e isso erraria o marco em um dia.'
    );
    Assert.areEqual(
      4,
      depois.SOL_Dias_Reuniao_Procuracao__c,
      'Com o marco correto na sexta, a etapa 3 dura quatro dias úteis.'
    );
  }

  @IsTest
  static void origemAsVinteETresETrintaUsaADataDeSaoPaulo() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = emSaoPaulo(SEGUNDA, 23, 30),
      SOL_Data_Primeira_Ligacao__c = as10(TERCA)
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Assert.areEqual(
      1,
      lead(l.Id).SOL_Dias_Primeira_Ligacao__c,
      'A origem é segunda em São Paulo, ainda que já seja terça em GMT: sobra um dia útil até a terça. ' +
      'Se o fuso fosse ignorado, o resultado seria 0.'
    );
  }

  @IsTest
  static void mesmoDiaGravaZeroENaoVazio() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = emSaoPaulo(QUARTA, 8, 30),
      SOL_Data_Primeira_Ligacao__c = emSaoPaulo(QUARTA, 17, 45)
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.areEqual(
      0,
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Distribuição e ligação no mesmo dia útil: a etapa durou ZERO dias úteis.'
    );
    Assert.isNotNull(
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Zero é um valor gravado; confundir zero com vazio quebraria a média do relatório.'
    );
  }

  @IsTest
  static void origemAusenteDeixaVazioSemPendencia() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(Id = l.Id, SOL_Data_Primeira_Ligacao__c = as10(QUARTA));

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.isNull(
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Sem a data de distribuição a etapa 1 não tem origem: fica vazia.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'Marco faltando não é pendência.'
    );
    Assert.isNull(
      depois.SOL_Duracao_Pendencia_Motivo__c,
      'Sem pendência não há motivo.'
    );
  }

  @IsTest
  static void destinoAusenteDeixaVazioSemPendencia() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(Id = l.Id, SOL_Data_Distribuicao__c = as10(SEGUNDA));

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.isNull(
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Sem a primeira ligação a etapa 1 não terminou: fica vazia.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'Etapa em aberto não é pendência de cálculo.'
    );
  }

  @IsTest
  static void destinoAnteriorAOrigemFicaVazioComPendenciaInconsistente() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEXTA),
      SOL_Data_Primeira_Ligacao__c = as10(SEGUNDA)
    );

    Test.startTest();
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.isNull(
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Intervalo incoerente NÃO vira número: a duração fica vazia.'
    );
    Assert.areNotEqual(
      0,
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Zero mentiria na média, puxando-a para baixo.'
    );
    Assert.isTrue(
      depois.SOL_Duracao_Pendente__c,
      'A incoerência precisa ficar VISÍVEL, não silenciosa.'
    );
    Assert.areEqual(
      SOLDuracaoEtapaService.MOTIVO_INCONSISTENTE,
      depois.SOL_Duracao_Pendencia_Motivo__c,
      'Dado inválido tem motivo próprio, distinto da falha de calendário.'
    );
    Assert.isTrue(
      depois.SOL_Duracao_Pendencia_Detalhe__c.contains('1 - Primeira ligação'),
      'O detalhe precisa dizer QUAL etapa está pendente: ' +
      depois.SOL_Duracao_Pendencia_Detalhe__c
    );
  }

  @IsTest
  static void reprocessamentoNaoAlteraValorJaGravado() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA)
    );
    recalcularLead(l.Id);
    Decimal primeiro = lead(l.Id).SOL_Dias_Primeira_Ligacao__c;

    Test.startTest();
    // Marcos alterados DEPOIS de a etapa ter sido concluída: a duração já
    // consolidada não pode ser reescrita.
    update new Lead(Id = l.Id, SOL_Data_Primeira_Ligacao__c = as10(SEXTA));
    recalcularLead(l.Id);
    Test.stopTest();

    Assert.areEqual(2, primeiro, 'Pré-condição: a primeira conclusão vale 2.');
    Assert.areEqual(
      primeiro,
      lead(l.Id).SOL_Dias_Primeira_Ligacao__c,
      'A primeira conclusão válida é CONGELADA: reprocessar não sobrescreve.'
    );
  }

  // ============================================ calendário indisponível

  @IsTest
  static void semCalendarioMarcoFicaGravadoEDuracaoFicaPendente() {
    Lead l = novoLead(PRODUTO_RT);

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    // A operação comercial (gravar os marcos) tem de concluir normalmente.
    update new Lead(
      Id = l.Id,
      SOL_Data_Contato_Efetivado__c = as10(SEGUNDA),
      SOL_Data_Reuniao_Realizada__c = as10(QUARTA),
      SOL_Data_Recebimento_Procuracao__c = SEXTA
    );
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.areEqual(
      as10(SEGUNDA),
      depois.SOL_Data_Contato_Efetivado__c,
      'O MARCO é gravado mesmo sem calendário: gravar data não depende de Business Hours.'
    );
    Assert.areEqual(
      SEXTA,
      depois.SOL_Data_Reuniao_Procuracao__c,
      'O marco consolidado da etapa 3 também é gravado sem calendário.'
    );
    Assert.isNull(
      depois.SOL_Dias_Reuniao_Procuracao__c,
      'A duração fica VAZIA — em nenhum caso ela vira 0 por falta de calendário.'
    );
    Assert.isTrue(
      depois.SOL_Duracao_Pendente__c,
      'A lacuna fica registrada e auditável.'
    );
    Assert.areEqual(
      SOLDuracaoEtapaService.MOTIVO_CALENDARIO,
      depois.SOL_Duracao_Pendencia_Motivo__c,
      'Falha de calendário é TRANSITÓRIA — é o único motivo que o Batch reprocessa.'
    );
  }

  @IsTest
  static void batchComCalendarioDeVoltaPreencheELimpaAPendencia() {
    Id calendarioReal = bh();
    Lead l = novoLead(PRODUTO_RT);

    SOLBusinessHoursHelper.overrideBusinessHours(null);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA)
    );
    recalcularLead(l.Id);
    Lead pendente = lead(l.Id);

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(calendarioReal);
    Database.executeBatch(
      new SOLDuracaoEtapaBatch(SOLDuracaoEtapaBatch.Escopo.LEAD),
      200
    );
    Test.stopTest();

    Assert.isTrue(
      pendente.SOL_Duracao_Pendente__c,
      'Pré-condição: sem calendário o registro ficou pendente.'
    );
    Assert.isNull(
      pendente.SOL_Dias_Primeira_Ligacao__c,
      'Pré-condição: a duração ficou vazia, não zero.'
    );

    Lead depois = lead(l.Id);
    Assert.areEqual(
      2,
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Com o calendário de volta, a varredura preenche a duração.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'E limpa a pendência: consistência analítica EVENTUAL, mas garantida.'
    );
    Assert.isNull(
      depois.SOL_Duracao_Pendencia_Motivo__c,
      'Sem pendência não sobra motivo.'
    );
    Assert.isNull(
      depois.SOL_Duracao_Pendencia_Detalhe__c,
      'Nem detalhe.'
    );
  }

  /**
   * Quando as duas situações coexistem, o motivo gravado é o TRANSITÓRIO — é o
   * único que o Batch reprocessa, e sem essa precedência a falha de calendário
   * ficaria presa para sempre atrás de um dado ruim.
   */
  @IsTest
  static void transitoriaPrevaleceSobreInconsistenteNoMesmoRegistro() {
    Lead l = novoLead(PRODUTO_RT);

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    update new Lead(
      Id = l.Id,
      // Etapa 1 incoerente (destino antes da origem) e etapa 2 sem calendário.
      SOL_Data_Distribuicao__c = as10(SEXTA),
      SOL_Data_Primeira_Ligacao__c = as10(SEGUNDA),
      SOL_Data_Contato_Efetivado__c = as10(QUARTA)
    );
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.isTrue(depois.SOL_Duracao_Pendente__c, 'Há pendência.');
    Assert.areEqual(
      SOLDuracaoEtapaService.MOTIVO_CALENDARIO,
      depois.SOL_Duracao_Pendencia_Motivo__c,
      'A transitória prevalece: é ela que ainda pode se resolver sozinha.'
    );
    Assert.isTrue(
      depois.SOL_Duracao_Pendencia_Detalhe__c.contains('inconsistente'),
      'O detalhe continua registrando as DUAS situações: ' +
      depois.SOL_Duracao_Pendencia_Detalhe__c
    );
  }

  // ==================================== etapas 4 a 6, na Oportunidade

  @IsTest
  static void etapa4CalculoJuridico() {
    Opportunity o = novaOpp(PRODUTO_RT);
    update new Opportunity(
      Id = o.Id,
      SOL_Data_Solicitacao_Calculo__c = SEGUNDA,
      SOL_Data_Recebimento_Calculo__c = SEXTA
    );

    Test.startTest();
    recalcularOpp(o.Id);
    Test.stopTest();

    Assert.areEqual(
      4,
      opp(o.Id).SOL_Dias_Calculo_Juridico__c,
      'Da solicitação na segunda ao recebimento na sexta: quatro dias úteis.'
    );
  }

  @IsTest
  static void etapa5ReuniaoFinal() {
    Opportunity o = novaOpp(PRODUTO_RT);
    update new Opportunity(
      Id = o.Id,
      SOL_Data_Recebimento_Calculo__c = SEXTA_ANTERIOR,
      SOL_Data_Reuniao_Final__c = TERCA
    );

    Test.startTest();
    recalcularOpp(o.Id);
    Test.stopTest();

    Assert.areEqual(
      2,
      opp(o.Id).SOL_Dias_Reuniao_Final__c,
      'Da sexta à terça, sem contar o fim de semana: segunda e terça.'
    );
  }

  @IsTest
  static void etapa6DoFechamento() {
    Opportunity o = novaOpp(PRODUTO_RT);
    update new Opportunity(
      Id = o.Id,
      SOL_Data_Reuniao_Final__c = SEGUNDA,
      SOL_Data_Encerramento__c = as10(QUINTA)
    );

    Test.startTest();
    recalcularOpp(o.Id);
    Test.stopTest();

    Assert.areEqual(
      3,
      opp(o.Id).SOL_Dias_Fechamento__c,
      'Da reunião final na segunda ao encerramento na quinta: terça, quarta e quinta.'
    );
  }

  /**
   * ART 360 não tem cálculo jurídico, reunião final nem fechamento por esse
   * caminho — e o resultado sai POR CONSTRUÇÃO, sem nenhuma regra por produto no
   * serviço: sem os marcos, as etapas ficam vazias.
   */
  @IsTest
  static void art360DeixaEtapas456VaziasNuncaZero() {
    Opportunity o = novaOpp(PRODUTO_ART);
    update new Opportunity(
      Id = o.Id,
      SOL_Data_Primeira_Ligacao__c = as10(SEGUNDA),
      SOL_Data_Inicio_Ciclo_Comercial__c = as10(QUARTA),
      SOL_Data_Reuniao_Procuracao__c = SEXTA
    );

    Test.startTest();
    recalcularOpp(o.Id);
    Test.stopTest();

    Opportunity depois = opp(o.Id);
    Assert.areEqual(
      2,
      depois.SOL_Dias_Contato_Efetivado__c,
      'As etapas 1 a 3 valem para ART 360 e são calculadas normalmente.'
    );
    Assert.areEqual(
      2,
      depois.SOL_Dias_Reuniao_Procuracao__c,
      'Etapa 3 em ART 360 também é calculada.'
    );
    Assert.isNull(
      depois.SOL_Dias_Calculo_Juridico__c,
      'ART 360 não tem cálculo jurídico: a etapa 4 fica VAZIA, nunca zero.'
    );
    Assert.isNull(
      depois.SOL_Dias_Reuniao_Final__c,
      'Etapa 5 vazia em ART 360.'
    );
    Assert.isNull(
      depois.SOL_Dias_Fechamento__c,
      'Etapa 6 vazia em ART 360.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'Etapa que não existe para o produto não é pendência.'
    );
  }

  @IsTest
  static void encerramentoEhGravadoEmGanhoEEmPerdido() {
    Opportunity ganha = novaOpp(PRODUTO_RT);
    Opportunity perdida = novaOpp(PRODUTO_RT);

    Test.startTest();
    update new Opportunity(Id = ganha.Id, StageName = 'Ganho');
    update new Opportunity(
      Id = perdida.Id,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem interesse'
    );
    Test.stopTest();

    Assert.isNotNull(
      opp(ganha.Id).SOL_Data_Encerramento__c,
      'A transição real para Ganho carimba o encerramento no próprio save.'
    );
    Assert.isNotNull(
      opp(perdida.Id).SOL_Data_Encerramento__c,
      'Perdido também encerra a jornada e fecha a etapa 6.'
    );
  }

  @IsTest
  static void encerramentoJaGravadoNaoEhReescrito() {
    Opportunity o = novaOpp(PRODUTO_RT);
    Datetime original = as10(SEGUNDA);
    update new Opportunity(Id = o.Id, SOL_Data_Encerramento__c = original);

    Test.startTest();
    update new Opportunity(Id = o.Id, StageName = 'Ganho');
    Test.stopTest();

    Assert.areEqual(
      original,
      opp(o.Id).SOL_Data_Encerramento__c,
      'O primeiro encerramento é preservado: reabrir e fechar de novo não reescreve o marco.'
    );
  }

  // ======================================= conversão e ressincronização

  @IsTest
  static void conversaoLevaOsSeisCamposParaAOportunidade() {
    Lead l = novoLead(PRODUTO_RT);
    // O anexo vem ANTES: a VR SOL_Conversao_Exige_Procuracao_Ou_Apto recusa
    // marcar a procuração como recebida sem arquivo no Lead.
    anexar(l.Id);
    update new Lead(
      Id = l.Id,
      Status = 'Apto para Conversão',
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA),
      SOL_Data_Contato_Efetivado__c = as10(QUINTA),
      SOL_Data_Reuniao_Realizada__c = as10(QUINTA),
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = SEXTA
    );
    recalcularLead(l.Id);
    Lead antes = lead(l.Id);

    Test.startTest();
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedido(l.Id) }
    )[0];
    Test.stopTest();

    Assert.isTrue(r.convertido, 'Pré-condição: a conversão precisa acontecer. ' + r.mensagem);
    Opportunity o = opp((Id) r.oportunidadeId);
    Assert.areEqual(
      antes.SOL_Data_Primeira_Ligacao__c,
      o.SOL_Data_Primeira_Ligacao__c,
      'Marco da primeira ligação transportado sem alteração.'
    );
    Assert.areEqual(
      antes.SOL_Data_Reuniao_Procuracao__c,
      o.SOL_Data_Reuniao_Procuracao__c,
      'Marco consolidado da etapa 3 transportado.'
    );
    Assert.areEqual(
      antes.SOL_Dias_Primeira_Ligacao__c,
      o.SOL_Dias_Primeira_Ligacao__c,
      'Etapa 1 chega à Oportunidade — ela não pode ser recalculada lá, porque a origem só existe no Lead.'
    );
    Assert.areEqual(
      antes.SOL_Dias_Contato_Efetivado__c,
      o.SOL_Dias_Contato_Efetivado__c,
      'Etapa 2 transportada.'
    );
    Assert.areEqual(
      antes.SOL_Dias_Reuniao_Procuracao__c,
      o.SOL_Dias_Reuniao_Procuracao__c,
      'Etapa 3 transportada.'
    );
    Assert.isFalse(
      o.SOL_Duracao_Pendente__c,
      'Sem pendência no Lead, a Oportunidade nasce sem pendência.'
    );
    Assert.isNotNull(
      antes.SOL_Dias_Primeira_Ligacao__c,
      'Pré-condição: o Lead precisa ter medição para o transporte provar alguma coisa.'
    );
  }

  /**
   * O buraco que este cenário fecha: com o calendário fora quando os marcos são
   * gravados, o Lead fica pendente e SEM duração. Se a conversão acontecer nessa
   * janela — antes da varredura das :45 —, a Oportunidade nasce sem as etapas 1
   * a 3, e a etapa 1 NÃO é recalculável lá, porque a origem dela
   * (SOL_Data_Distribuicao__c) só existe no Lead. A ressincronização é o que
   * conserta isso depois.
   *
   * A sequência é a real, não uma simulação de laboratório: calendário fora na
   * gravação dos marcos, calendário de volta na hora de converter (a conversão
   * EXIGE calendário — SOLPrazoTotalService aborta sem ele, e é o contraste
   * deliberado de política deste card), varredura depois.
   */
  @IsTest
  static void leadCorrigidoDepoisDaConversaoRessincronizaAOportunidade() {
    Id calendarioReal = bh();
    Lead l = novoLead(PRODUTO_RT);
    anexar(l.Id);

    SOLBusinessHoursHelper.overrideBusinessHours(null);
    update new Lead(
      Id = l.Id,
      Status = 'Apto para Conversão',
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA),
      SOL_Data_Contato_Efetivado__c = as10(QUINTA),
      SOL_Data_Reuniao_Realizada__c = as10(QUINTA),
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = SEXTA
    );
    recalcularLead(l.Id);
    Lead pendente = lead(l.Id);
    Assert.isTrue(
      pendente.SOL_Duracao_Pendente__c,
      'Pré-condição: sem calendário o Lead fica pendente.'
    );
    Assert.isNull(
      pendente.SOL_Dias_Primeira_Ligacao__c,
      'Pré-condição: a etapa 1 ficou vazia, não zero.'
    );

    // Calendário de volta. Sem ele a conversão nem aconteceria.
    SOLBusinessHoursHelper.overrideBusinessHours(calendarioReal);
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedido(l.Id) }
    )[0];
    Assert.isTrue(
      r.convertido,
      'A conversão acontece normalmente: a pendência analítica não a bloqueia. ' +
      r.mensagem
    );
    Id oppId = (Id) r.oportunidadeId;
    Opportunity recemNascida = opp(oppId);
    Assert.isNull(
      recemNascida.SOL_Dias_Primeira_Ligacao__c,
      'Pré-condição: a Oportunidade nasceu sem a etapa 1, porque o Lead ainda não tinha o número.'
    );
    Assert.isTrue(
      recemNascida.SOL_Duracao_Pendente__c,
      'A pendência viaja com a conversão — a lacuna continua visível do lado da Oportunidade.'
    );

    Test.startTest();
    // A varredura conserta o Lead convertido e a correção DESCE para a
    // Oportunidade, na mesma passagem.
    Database.executeBatch(
      new SOLDuracaoEtapaBatch(SOLDuracaoEtapaBatch.Escopo.LEAD),
      200
    );
    Test.stopTest();

    Assert.areEqual(
      2,
      lead(l.Id).SOL_Dias_Primeira_Ligacao__c,
      'O Lead convertido continua alcançável pela varredura e é calculado.'
    );
    Assert.areEqual(
      2,
      opp(oppId).SOL_Dias_Primeira_Ligacao__c,
      'E o valor DESCE para a Oportunidade — sem isso o relatório perderia a etapa 1 para sempre.'
    );

    // Em produção o Batch encadeia o escopo de Oportunidade no finish(); em
    // teste o encadeamento é suprimido, então a segunda metade é exercitada
    // aqui pelo mesmo caminho de código.
    SOLDuracaoEtapaService.recalcularOportunidades(new List<Id>{ oppId });
    Opportunity depois = opp(oppId);
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'Com as etapas resolvidas, a pendência da Oportunidade é limpa.'
    );
    Assert.areEqual(
      1,
      depois.SOL_Dias_Contato_Efetivado__c,
      'A etapa 2 é recalculada na própria Oportunidade, a partir dos marcos dela.'
    );
  }

  private static SOL_ConverterLead.Pedido pedido(Id leadId) {
    SOL_ConverterLead.Pedido p = new SOL_ConverterLead.Pedido();
    p.leadId = leadId;
    p.contaId = null;
    return p;
  }

  private static void anexar(Id registroId) {
    ContentVersion cv = new ContentVersion(
      Title = 'Procuracao ' + rnd().left(6),
      PathOnClient = 'procuracao.txt',
      VersionData = Blob.valueOf('documento')
    );
    insert cv;
    Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = docId,
      LinkedEntityId = registroId,
      ShareType = 'V'
    );
  }

  // ============================================================ reatribuição

  @IsTest
  static void reatribuicaoNaoReiniciaMarcosNemDuracoes() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA)
    );
    recalcularLead(l.Id);
    Lead antes = lead(l.Id);

    Test.startTest();
    // A reatribuição troca o dono e a data da última reatribuição; nunca toca
    // SOL_Data_Distribuicao__c (verificado no código do CLICKUP-9394/9400).
    update new Lead(
      Id = l.Id,
      OwnerId = UserInfo.getUserId(),
      SOL_Data_Ultima_Reatribuicao__c = System.now()
    );
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.areEqual(
      antes.SOL_Data_Distribuicao__c,
      depois.SOL_Data_Distribuicao__c,
      'A reatribuição não reinicia o marco de origem da etapa 1.'
    );
    Assert.areEqual(
      antes.SOL_Dias_Primeira_Ligacao__c,
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Nem a duração já consolidada.'
    );
    Assert.areEqual(2, depois.SOL_Dias_Primeira_Ligacao__c, 'O valor continua o mesmo.');
  }

  // ==================================================================== bulk

  /**
   * BULK — o que este teste prova, literalmente: um lote de 200 Leads monta o
   * acumulado do calendário UMA VEZ. A instrumentação
   * `SOLDuracaoEtapaService.contadoresMontados` conta construções do acumulado;
   * cada construção é a única coisa que chama `BusinessHours.nextStartDate`, e
   * ela o faz uma vez por DIA DE CALENDÁRIO do lote, não por registro.
   *
   * O que ele NÃO prova: um número absoluto de CPU time. Medir CPU em teste é
   * instável e diria menos do que a contagem direta.
   */
  @IsTest
  static void loteDeDuzentosMontaOCalendarioUmaVezSo() {
    List<Lead> leads = new List<Lead>();
    Id rt = rtLead();
    Database.DMLOptions opc = new Database.DMLOptions();
    opc.duplicateRuleHeader.allowSave = true;
    for (Integer i = 0; i < 200; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rt,
          FirstName = 'Bulk',
          LastName = 'Lead ' + i,
          Company = 'Empresa ' + i,
          CNPJ__c = CNPJ,
          SOL_Produto_Interesse__c = PRODUTO_RT
        )
      );
    }
    Database.insert(leads, opc);

    List<Lead> comMarcos = new List<Lead>();
    List<Id> ids = new List<Id>();
    for (Integer i = 0; i < leads.size(); i++) {
      comMarcos.add(
        new Lead(
          Id = leads[i].Id,
          OwnerId = UserInfo.getUserId(),
          SOL_Data_Distribuicao__c = as10(SEGUNDA),
          SOL_Data_Primeira_Ligacao__c = as10(Math.mod(i, 2) == 0 ? QUARTA : SEXTA)
        )
      );
      ids.add(leads[i].Id);
    }
    update comMarcos;

    Test.startTest();
    SOLDuracaoEtapaService.zerarInstrumentacao();
    SOLDuracaoEtapaService.ResultadoDuracao r = SOLDuracaoEtapaService.recalcularLeads(
      ids
    );
    Integer consultas = Limits.getQueries();
    Integer dmls = Limits.getDmlStatements();
    Test.stopTest();

    Assert.areEqual(
      1,
      SOLDuracaoEtapaService.contadoresMontados,
      'O calendário do lote é pré-computado UMA vez. Mais de uma significaria contagem por registro, que estoura CPU num backfill.'
    );
    Assert.areEqual(
      200,
      r.avaliados,
      'Os 200 Leads foram avaliados.'
    );
    Assert.areEqual(
      200,
      r.calculadas,
      'Uma etapa calculada por Lead — as outras duas estão sem marco.'
    );
    Assert.isTrue(
      consultas <= 10,
      'Sem SOQL em laço: o lote inteiro cabe em poucas consultas, e foram ' + consultas
    );
    Assert.isTrue(
      dmls <= 5,
      'Sem DML em laço: uma gravação por lote, e foram ' + dmls
    );

    Integer conferidos = 0;
    for (Lead l : [
      SELECT Id, SOL_Dias_Primeira_Ligacao__c
      FROM Lead
      WHERE Id IN :ids
    ]) {
      Assert.isTrue(
        l.SOL_Dias_Primeira_Ligacao__c == 2 || l.SOL_Dias_Primeira_Ligacao__c == 4,
        'Cada Lead recebeu a contagem do SEU par de marcos, não a do vizinho: ' +
        l.SOL_Dias_Primeira_Ligacao__c
      );
      conferidos++;
    }
    Assert.areEqual(200, conferidos, 'Todos os 200 foram conferidos.');
  }

  /**
   * BULK do outro lado: 200 Oportunidades num lote, mesma prova. O acumulado do
   * calendário é montado UMA vez para as 200, e cada uma recebe a contagem do
   * SEU par de marcos.
   */
  @IsTest
  static void loteDeDuzentasOportunidadesMontaOCalendarioUmaVezSo() {
    Account a = new Account(Name = 'Conta bulk ' + rnd());
    insert a;
    Id rt = rtOpp();
    List<Opportunity> opps = new List<Opportunity>();
    for (Integer i = 0; i < 200; i++) {
      opps.add(
        new Opportunity(
          Name = 'Op bulk ' + i,
          AccountId = a.Id,
          RecordTypeId = rt,
          CloseDate = Date.today().addDays(60),
          StageName = 'Diagnóstico',
          SOL_Produto_Negocio__c = PRODUTO_RT,
          SOL_Data_Solicitacao_Calculo__c = SEGUNDA,
          SOL_Data_Recebimento_Calculo__c = Math.mod(i, 2) == 0 ? QUARTA : SEXTA
        )
      );
    }
    insert opps;

    List<Id> ids = new List<Id>(new Map<Id, Opportunity>(opps).keySet());

    Test.startTest();
    SOLDuracaoEtapaService.zerarInstrumentacao();
    SOLDuracaoEtapaService.ResultadoDuracao r = SOLDuracaoEtapaService.recalcularOportunidades(
      ids
    );
    Integer consultas = Limits.getQueries();
    Integer dmls = Limits.getDmlStatements();
    Test.stopTest();

    Assert.areEqual(
      1,
      SOLDuracaoEtapaService.contadoresMontados,
      'O calendário do lote de Oportunidades também é pré-computado UMA vez.'
    );
    Assert.areEqual(200, r.avaliados, 'As 200 Oportunidades foram avaliadas.');
    Assert.areEqual(
      200,
      r.calculadas,
      'Uma etapa calculada por Oportunidade — as outras quatro estão sem marco.'
    );
    Assert.isTrue(
      consultas <= 10,
      'Sem SOQL em laço, e foram ' + consultas
    );
    Assert.isTrue(dmls <= 5, 'Sem DML em laço, e foram ' + dmls);

    Integer conferidas = 0;
    for (Opportunity o : [
      SELECT Id, SOL_Dias_Calculo_Juridico__c
      FROM Opportunity
      WHERE Id IN :ids
    ]) {
      Assert.isTrue(
        o.SOL_Dias_Calculo_Juridico__c == 2 || o.SOL_Dias_Calculo_Juridico__c == 4,
        'Cada Oportunidade recebeu a contagem do SEU par: ' +
        o.SOL_Dias_Calculo_Juridico__c
      );
      conferidas++;
    }
    Assert.areEqual(200, conferidas, 'Todas as 200 foram conferidas.');
  }

  /**
   * OPT-OUT antes da conversão: o Lead guarda as etapas 1 a 3 que realmente
   * aconteceram, e as etapas 4 a 6 não existem em lugar nenhum — porque não
   * existe Oportunidade. Nada vira zero, nada fica pendente.
   */
  @IsTest
  static void optOutAntesDaConversaoNaoProduzEtapasDaOportunidade() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA),
      SOL_Data_Contato_Efetivado__c = as10(QUINTA)
    );
    recalcularLead(l.Id);

    Test.startTest();
    // Pelo caminho REAL do CLICKUP-9418: o servico desqualifica o Lead, grava a
    // data do opt-out e cancela as tarefas pendentes. Marcar o checkbox a mao
    // seria recusado pela VR SOL_Desqualificacao_Coerente, e com razao.
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    recalcularLead(l.Id);
    Test.stopTest();

    Lead depois = lead(l.Id);
    Assert.areEqual(
      2,
      depois.SOL_Dias_Primeira_Ligacao__c,
      'O opt-out não apaga a etapa 1 que já tinha acontecido.'
    );
    Assert.areEqual(
      1,
      depois.SOL_Dias_Contato_Efetivado__c,
      'Nem a etapa 2.'
    );
    Assert.isNull(
      depois.SOL_Dias_Reuniao_Procuracao__c,
      'A etapa 3 não terminou e fica VAZIA — o opt-out não a fecha com zero.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'Etapa interrompida por opt-out não é pendência de cálculo.'
    );
    Assert.isFalse(depois.IsConverted, 'O Lead não foi convertido.');
    Assert.isNull(
      depois.ConvertedOpportunityId,
      'Sem Oportunidade, as etapas 4 a 6 não existem em lugar nenhum — não são zero, são inexistentes.'
    );
  }

  // ===================================================================== FLS

  @IsTest
  static void flsEstruturalNosDoisPermissionSets() {
    Set<String> campos = new Set<String>{
      'Lead.SOL_Data_Primeira_Ligacao__c',
      'Lead.SOL_Data_Reuniao_Procuracao__c',
      'Lead.SOL_Dias_Primeira_Ligacao__c',
      'Lead.SOL_Dias_Contato_Efetivado__c',
      'Lead.SOL_Dias_Reuniao_Procuracao__c',
      'Lead.SOL_Duracao_Pendente__c',
      'Lead.SOL_Duracao_Pendencia_Motivo__c',
      'Lead.SOL_Duracao_Pendencia_Detalhe__c',
      'Opportunity.SOL_Data_Primeira_Ligacao__c',
      'Opportunity.SOL_Data_Reuniao_Procuracao__c',
      'Opportunity.SOL_Data_Recebimento_Calculo__c',
      'Opportunity.SOL_Data_Reuniao_Final__c',
      'Opportunity.SOL_Data_Encerramento__c',
      'Opportunity.SOL_Dias_Primeira_Ligacao__c',
      'Opportunity.SOL_Dias_Contato_Efetivado__c',
      'Opportunity.SOL_Dias_Reuniao_Procuracao__c',
      'Opportunity.SOL_Dias_Calculo_Juridico__c',
      'Opportunity.SOL_Dias_Reuniao_Final__c',
      'Opportunity.SOL_Dias_Fechamento__c',
      'Opportunity.SOL_Duracao_Pendente__c',
      'Opportunity.SOL_Duracao_Pendencia_Motivo__c',
      'Opportunity.SOL_Duracao_Pendencia_Detalhe__c'
    };
    Set<String> conjuntos = new Set<String>{
      'PS_SOL_Comercial',
      'PS_SOL_Distribuicao_Admin'
    };

    Map<String, FieldPermissions> encontrados = new Map<String, FieldPermissions>();
    for (FieldPermissions fp : [
      SELECT Field, PermissionsRead, PermissionsEdit, Parent.Name
      FROM FieldPermissions
      WHERE Parent.Name IN :conjuntos AND Field IN :campos
    ]) {
      encontrados.put(fp.Parent.Name + '|' + fp.Field, fp);
    }

    for (String ps : conjuntos) {
      for (String campo : campos) {
        FieldPermissions fp = encontrados.get(ps + '|' + campo);
        Assert.isNotNull(
          fp,
          'Falta FLS de ' + campo + ' em ' + ps + '.'
        );
        Assert.isTrue(
          fp.PermissionsRead,
          campo + ' precisa ser LEGÍVEL em ' + ps + '.'
        );
        Assert.isFalse(
          fp.PermissionsEdit,
          campo +
          ' NÃO pode ser editável em ' +
          ps +
          ': é campo técnico escrito só pela automação.'
        );
      }
    }
  }

  /**
   * FLS EFETIVA — medida por `getDescribe()` sob `System.runAs`, e não por um
   * `update` de verdade: DML de Apex roda em modo de sistema e NÃO aplica FLS,
   * então um update que passasse não provaria nada.
   */
  @IsTest
  static void flsEfetivoEhSomenteLeitura() {
    User vendedor = new User(
      FirstName = 'FLS',
      LastName = 'Duracao',
      Alias = 'flsdur',
      Email = 'fls.duracao@arnone.invalid',
      Username = 'fls.duracao.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9439.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
    insert vendedor;
    List<PermissionSet> ps = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'PS_SOL_Comercial'
      LIMIT 1
    ];
    Assert.areEqual(1, ps.size(), 'Pré-condição: PS_SOL_Comercial precisa existir.');
    insert new PermissionSetAssignment(
      AssigneeId = vendedor.Id,
      PermissionSetId = ps[0].Id
    );

    Test.startTest();
    System.runAs(vendedor) {
      Schema.DescribeFieldResult dias = Lead.SOL_Dias_Primeira_Ligacao__c.getDescribe();
      Assert.isTrue(
        dias.isAccessible(),
        'O vendedor precisa LER a duração para o relatório fazer sentido.'
      );
      Assert.isFalse(
        dias.isUpdateable(),
        'O vendedor NÃO pode editar a duração: o número tem de vir da automação.'
      );

      Schema.DescribeFieldResult pendente = Opportunity.SOL_Duracao_Pendente__c.getDescribe();
      Assert.isTrue(pendente.isAccessible(), 'A pendência precisa ser visível.');
      Assert.isFalse(
        pendente.isUpdateable(),
        'Ninguém "resolve" a pendência apagando o checkbox à mão.'
      );

      Schema.DescribeFieldResult encerramento = Opportunity.SOL_Data_Encerramento__c.getDescribe();
      Assert.isTrue(encerramento.isAccessible(), 'O encerramento é visível.');
      Assert.isFalse(
        encerramento.isUpdateable(),
        'O marco de encerramento é gravado pelo Flow before-save, nunca digitado.'
      );
    }
    Test.stopTest();
  }

  private static Id perfilStandard() {
    Map<String, Id> porNome = new Map<String, Id>();
    for (Profile p : [SELECT Id, Name FROM Profile WHERE UserType = 'Standard']) {
      porNome.put(p.Name, p.Id);
    }
    if (porNome.containsKey('Standard User')) {
      return porNome.get('Standard User');
    }
    return porNome.isEmpty() ? UserInfo.getProfileId() : porNome.values()[0];
  }

  // =================================================================== Batch

  @IsTest
  static void backfillIdempotenteRodandoDuasVezes() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Contato_Efetivado__c = as10(SEGUNDA),
      SOL_Data_Reuniao_Realizada__c = as10(QUARTA),
      SOL_Data_Recebimento_Procuracao__c = SEXTA
    );
    // Apaga a medição para simular um registro histórico, anterior ao card.
    update new Lead(
      Id = l.Id,
      SOL_Data_Reuniao_Procuracao__c = null,
      SOL_Dias_Reuniao_Procuracao__c = null,
      SOL_Dias_Contato_Efetivado__c = null,
      SOL_Duracao_Pendente__c = false,
      SOL_Duracao_Pendencia_Motivo__c = null,
      SOL_Duracao_Pendencia_Detalhe__c = null
    );

    Test.startTest();
    Database.executeBatch(
      new SOLDuracaoEtapaBatch(SOLDuracaoEtapaBatch.Escopo.LEAD),
      200
    );
    Test.stopTest();

    Lead primeira = lead(l.Id);
    Assert.areEqual(
      SEXTA,
      primeira.SOL_Data_Reuniao_Procuracao__c,
      'O backfill consolida o marco da etapa 3 a partir dos dois insumos que já existiam.'
    );
    Assert.areEqual(
      4,
      primeira.SOL_Dias_Reuniao_Procuracao__c,
      'E calcula a duração.'
    );

    // Segunda passagem, fora do startTest/stopTest — o Batch já rodou; aqui a
    // idempotência é provada pelo serviço, que é o mesmo caminho do Batch.
    SOLDuracaoEtapaService.ResultadoDuracao r = SOLDuracaoEtapaService.recalcularLeads(
      new List<Id>{ l.Id }
    );
    Lead segunda = lead(l.Id);
    Assert.areEqual(
      primeira.SOL_Dias_Reuniao_Procuracao__c,
      segunda.SOL_Dias_Reuniao_Procuracao__c,
      'Rodar de novo produz exatamente o mesmo resultado.'
    );
    Assert.areEqual(
      0,
      r.calculadas,
      'A segunda passagem não calcula nada: tudo já estava preenchido.'
    );
    Assert.areEqual(
      0,
      r.marcosConsolidados,
      'E não consolida marco nenhum de novo.'
    );
  }

  @IsTest
  static void batchIgnoraRegistroSemMarcoENaoMarcaPendencia() {
    Lead semMarco = novoLead(PRODUTO_RT);
    update new Lead(
      Id = semMarco.Id,
      SOL_Data_Distribuicao__c = as10(SEGUNDA)
    );

    Test.startTest();
    Database.executeBatch(
      new SOLDuracaoEtapaBatch(SOLDuracaoEtapaBatch.Escopo.LEAD),
      200
    );
    Test.stopTest();

    Lead depois = lead(semMarco.Id);
    Assert.isNull(
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Sem a primeira ligação o backfill NÃO inventa marco nem preenche com zero.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'E não marca pendência: a etapa simplesmente não terminou.'
    );
  }

  /**
   * A varredura automática recusa o motivo "Intervalo inconsistente" — sem isso
   * o registro entraria em retry perpétuo, recusado do mesmo jeito toda hora.
   * A correção é humana: arrumar as datas e rodar o Batch com
   * `incluirInconsistentes`.
   */
  @IsTest
  static void varreduraAutomaticaNaoReprocessaInconsistenteMasSobDemandaSim() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEXTA),
      SOL_Data_Primeira_Ligacao__c = as10(SEGUNDA)
    );
    recalcularLead(l.Id);
    Assert.areEqual(
      SOLDuracaoEtapaService.MOTIVO_INCONSISTENTE,
      lead(l.Id).SOL_Duracao_Pendencia_Motivo__c,
      'Pré-condição: o registro ficou marcado como inconsistente.'
    );

    // Datas corrigidas por um humano, mas ninguém tocou no registro depois.
    update new Lead(Id = l.Id, SOL_Data_Distribuicao__c = as10(SEGUNDA));

    Test.startTest();
    Database.executeBatch(
      new SOLDuracaoEtapaBatch(SOLDuracaoEtapaBatch.Escopo.LEAD),
      200
    );
    Test.stopTest();

    Assert.isNull(
      lead(l.Id).SOL_Dias_Primeira_Ligacao__c,
      'A varredura AUTOMÁTICA não alcança o motivo inconsistente — por desenho, para não repetir a recusa para sempre.'
    );

    // Execução sob demanda, decidida por gente, depois da correção.
    SOLDuracaoEtapaService.recalcularLeads(new List<Id>{ l.Id });
    Lead depois = lead(l.Id);
    Assert.areEqual(
      0,
      depois.SOL_Dias_Primeira_Ligacao__c,
      'Com as datas corrigidas (mesmo dia útil), a duração passa a ser 0.'
    );
    Assert.isFalse(
      depois.SOL_Duracao_Pendente__c,
      'E a pendência é limpa.'
    );
  }

  // ================================================================ Invocable

  /**
   * A porta NUNCA relança — o oposto deliberado da porta estrita do
   * CLICKUP-9449. Aqui, engolir não persiste dado falso: persiste vazio mais
   * pendência.
   */
  @IsTest
  static void invocableNuncaRelancaEDescartaObjetoErrado() {
    Lead l = novoLead(PRODUTO_RT);
    update new Lead(
      Id = l.Id,
      SOL_Data_Distribuicao__c = as10(SEGUNDA),
      SOL_Data_Primeira_Ligacao__c = as10(QUARTA)
    );
    Account a = new Account(Name = 'Fora do escopo ' + rnd());
    insert a;

    List<SOLDuracaoEtapaInvocable.Entrada> entradas = new List<SOLDuracaoEtapaInvocable.Entrada>();
    SOLDuracaoEtapaInvocable.Entrada valida = new SOLDuracaoEtapaInvocable.Entrada();
    valida.recordId = l.Id;
    entradas.add(valida);
    SOLDuracaoEtapaInvocable.Entrada errada = new SOLDuracaoEtapaInvocable.Entrada();
    errada.recordId = a.Id;
    entradas.add(errada);
    SOLDuracaoEtapaInvocable.Entrada nula = new SOLDuracaoEtapaInvocable.Entrada();
    nula.recordId = null;
    entradas.add(nula);

    Test.startTest();
    SOLDuracaoEtapaInvocable.recalcular(entradas);
    // Sem calendário e com entrada inválida a porta continua sem relançar.
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    SOLDuracaoEtapaInvocable.recalcular(entradas);
    SOLDuracaoEtapaInvocable.recalcular(null);
    SOLDuracaoEtapaInvocable.recalcular(
      new List<SOLDuracaoEtapaInvocable.Entrada>()
    );
    Test.stopTest();

    Assert.areEqual(
      2,
      lead(l.Id).SOL_Dias_Primeira_Ligacao__c,
      'O Lead válido do lote foi medido, apesar da Account e do nulo no meio.'
    );
  }
}
