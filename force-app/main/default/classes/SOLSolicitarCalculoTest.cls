/**
 * CLICKUP-9420 — Card 09 — Testes do registro da solicitação (externa) do
 * cálculo ao jurídico.
 *
 * SOLSolicitarCalculoService.registrar grava Opportunity.SOL_Data_Solicitacao_Calculo__c
 * UMA ÚNICA VEZ, e só quando: Opp Record Type SOL + produto "Recuperação
 * Tributária" + aberta + etapa "Diagnóstico"; Lead convertido vinculado por
 * ConvertedOpportunityId; no Lead — SOL_Data_Reuniao_Realizada__c preenchida,
 * procuração "Recebida" com data; documento (ContentDocumentLink) no Lead OU na
 * Oportunidade. Data futura é rejeitada. Falha técnica aborta atomicamente
 * (Savepoint + rollback) e relança SolicitacaoCalculoException.
 *
 * Este card NÃO calcula vencimento nem cria tarefa — os testes verificam isso.
 * ART 360 fica fora: o funil dele vai direto para "Negociação".
 *
 * Estratégia de cenário: a maioria dos testes vincula um Lead comum (sem Record
 * Type SOL) a uma Opp SOL criada à mão, via Database.LeadConvert.setOpportunityId.
 * Isso permite montar de forma determinística estados que a jornada real (com as
 * validações do CLICKUP-9419 e a VR SOL_Conversao_Exige_Procuracao_Ou_Apto) não
 * deixaria existir — ex.: Opp convertida cujo Lead está sem reunião ou sem
 * procuração. Há também um teste com CONVERSÃO SOL REAL (produto Recuperação
 * Tributária, reunião + procuração + arquivo) provando o caminho ponta a ponta e
 * a regressão do CLICKUP-9419.
 *
 * Concorrência: a proteção é o SELECT ... FOR UPDATE em registrar(), que
 * serializa gravações concorrentes do MESMO registro no nível do banco. Duas
 * transações paralelas NÃO são simuláveis em teste Apex — os testes cobrem a
 * idempotência SEQUENCIAL (chamadas repetidas).
 */
@IsTest
private class SOLSolicitarCalculoTest {
  private static final String CNPJ = '11222333000181';
  private static final String PRODUTO = 'Recuperação Tributária';
  private static Integer seq = 0;

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static String rnd() {
    seq++;
    return seq + 'x' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
  }

  private static String convStatus() {
    return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1]
      .MasterLabel;
  }

  private static Id rtOppSOL() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id rtLeadSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static void anexar(Id alvo) {
    ContentVersion cv = new ContentVersion(
      Title = 'doc' + rnd(),
      PathOnClient = 'proc.txt',
      VersionData = Blob.valueOf('doc')
    );
    insert cv;
    insert new ContentDocumentLink(
      ContentDocumentId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId,
      LinkedEntityId = alvo,
      ShareType = 'V'
    );
  }

  /** Configuração de cenário — valores default montam o caminho feliz. */
  private class Cfg {
    String prodOpp = PRODUTO;
    String etapaOpp = 'Diagnóstico';
    Boolean oppSOL = true;
    Boolean comLead = true;
    Boolean reuniao = true;
    String statusProc = 'Recebida';
    Boolean dataProc = true;
    Boolean docLead = true;
    Boolean docOpp = false;
    Id oppOwner = null;
  }

  private class Ctx {
    Id oppId;
    Id leadId;
    Id accId;
  }

  private static Ctx montar(Cfg cfg) {
    Ctx x = new Ctx();

    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    x.accId = a.Id;

    Contact c = new Contact(LastName = 'Contato ' + rnd(), AccountId = a.Id);
    insert c;

    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd(),
      AccountId = a.Id,
      CloseDate = Date.today().addDays(60),
      StageName = 'Diagnóstico',
      SOL_Produto_Negocio__c = cfg.prodOpp
    );
    if (cfg.oppSOL) {
      o.RecordTypeId = rtOppSOL();
    }
    if (cfg.etapaOpp == 'Negociação') {
      o.SOL_ECAC_Consulta_Realizada__c = true;
      o.SOL_ECAC_Data_Consulta__c = Date.today();
      o.SOL_ECAC_Resultado__c = 'Valor a recuperar';
      o.SOL_Valor_Recuperavel__c = 1000;
      o.StageName = 'Negociação';
    } else if (cfg.etapaOpp == 'Perdido') {
      o.SOL_Motivo_Perda__c = 'Sem interesse';
      o.StageName = 'Perdido';
    } else {
      o.StageName = cfg.etapaOpp;
    }
    if (cfg.oppOwner != null) {
      o.OwnerId = cfg.oppOwner;
    }
    insert o;
    x.oppId = o.Id;

    if (cfg.comLead) {
      Lead l = new Lead(LastName = 'Lead ' + rnd(), Company = 'C');
      insert l;
      update new Lead(
        Id = l.Id,
        SOL_Data_Reuniao_Realizada__c = cfg.reuniao
          ? Datetime.now().addDays(-1)
          : null,
        SOL_Status_Procuracao__c = cfg.statusProc,
        SOL_Data_Recebimento_Procuracao__c = cfg.dataProc
          ? Date.today().addDays(-1)
          : null
      );
      if (cfg.docLead) {
        anexar(l.Id);
      }
      Database.LeadConvert lc = new Database.LeadConvert();
      lc.setLeadId(l.Id);
      lc.setAccountId(a.Id);
      lc.setContactId(c.Id);
      lc.setOpportunityId(o.Id);
      lc.setConvertedStatus(convStatus());
      Database.convertLead(lc);
      x.leadId = l.Id;
    }

    if (cfg.docOpp) {
      anexar(o.Id);
    }
    return x;
  }

  private static SOLSolicitarCalculoService.Resultado reg(Id oppId, Date d) {
    return SOLSolicitarCalculoService.registrar(
        new List<SOLSolicitarCalculoService.Pedido>{
          new SOLSolicitarCalculoService.Pedido(oppId, d)
        }
      )[0];
  }

  private static Date campoData(Id oppId) {
    return [
      SELECT SOL_Data_Solicitacao_Calculo__c
      FROM Opportunity
      WHERE Id = :oppId
    ]
    .SOL_Data_Solicitacao_Calculo__c;
  }

  private static Integer tarefasDa(Id oppId) {
    return [SELECT COUNT() FROM Task WHERE WhatId = :oppId];
  }

  private static Integer tarefasAcompanhamentoCalculo(Id oppId) {
    return [
      SELECT COUNT()
      FROM Task
      WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = 'Acompanhamento do cálculo jurídico'
    ];
  }

  // ============================================================ POSITIVO

  @IsTest
  static void registroValido_dataDeHoje() {
    Ctx x = montar(new Cfg());
    Date hoje = Date.today();

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, hoje);
    Test.stopTest();

    System.assert(r.sucesso, 'Caminho feliz grava a data. ' + r.mensagem);
    System.assertEquals(false, r.jaRegistrado);
    System.assertEquals(hoje, campoData(x.oppId));
    // O Card 09 não cria tarefa; a tarefa de acompanhamento do cálculo é do
    // CLICKUP-9421 (Flow after-save em Opportunity), disparado por este registro.
    System.assertEquals(1, tarefasDa(x.oppId), 'Só a tarefa de acompanhamento (CLICKUP-9421).');
    System.assertEquals(1, tarefasAcompanhamentoCalculo(x.oppId));
  }

  @IsTest
  static void registroValido_dataPassada() {
    Ctx x = montar(new Cfg());
    Date ontem = Date.today().addDays(-10);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, ontem);
    Test.stopTest();

    System.assert(r.sucesso, r.mensagem);
    System.assertEquals(ontem, campoData(x.oppId), 'Data passada é aceita.');
  }

  @IsTest
  static void documentoApenasNoLead() {
    Cfg cfg = new Cfg();
    cfg.docLead = true;
    cfg.docOpp = false;
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assert(r.sucesso, 'Documento no Lead satisfaz a exigência. ' + r.mensagem);
  }

  @IsTest
  static void documentoApenasNaOportunidade() {
    Cfg cfg = new Cfg();
    cfg.docLead = false;
    cfg.docOpp = true;
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assert(
      r.sucesso,
      'Documento transferido para a Oportunidade satisfaz a exigência. ' + r.mensagem
    );
  }

  // ============================================================ DATA

  @IsTest
  static void dataFuturaBloqueada() {
    Ctx x = montar(new Cfg());

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today().addDays(1));
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assertEquals(false, r.jaRegistrado);
    System.assert(r.mensagem.containsIgnoreCase('futura'), r.mensagem);
    System.assertEquals(null, campoData(x.oppId), 'Nada gravado.');
  }

  @IsTest
  static void dataObrigatoria() {
    Ctx x = montar(new Cfg());

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, null);
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('Informe a data'), r.mensagem);
    System.assertEquals(null, campoData(x.oppId));
  }

  // ============================================================ SOLICITAÇÃO ÚNICA

  @IsTest
  static void segundaTentativaNaoSobrescreve() {
    Ctx x = montar(new Cfg());
    Date primeira = Date.today().addDays(-3);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r1 = reg(x.oppId, primeira);
    SOLSolicitarCalculoService.Resultado r2 = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assert(r1.sucesso);
    System.assertEquals(false, r2.sucesso);
    System.assert(r2.jaRegistrado, 'Segunda tentativa: já registrado.');
    System.assert(r2.mensagem.containsIgnoreCase('já foi registrada'), r2.mensagem);
    System.assertEquals(primeira, campoData(x.oppId), 'Valor original preservado.');
  }

  @IsTest
  static void chamadasRepetidasSaoIdempotentes() {
    // Idempotência SEQUENCIAL — a concorrência real é protegida pelo
    // SELECT ... FOR UPDATE, não simulada aqui (ver nota da classe).
    Ctx x = montar(new Cfg());
    Date d = Date.today();

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r1 = reg(x.oppId, d);
    SOLSolicitarCalculoService.Resultado r2 = reg(x.oppId, d);
    SOLSolicitarCalculoService.Resultado r3 = reg(x.oppId, d);
    Test.stopTest();

    System.assert(r1.sucesso);
    System.assert(r2.jaRegistrado && !r2.sucesso);
    System.assert(r3.jaRegistrado && !r3.sucesso);
    System.assertEquals(d, campoData(x.oppId));
  }

  // ============================================================ PROTEÇÕES DA OPP

  @IsTest
  static void oportunidadeDeOutraBU() {
    Cfg cfg = new Cfg();
    cfg.oppSOL = false;
    cfg.comLead = false;
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('Arnone Soluções'), r.mensagem);
    System.assertEquals(null, campoData(x.oppId));
  }

  @IsTest
  static void oportunidadeART360() {
    Cfg cfg = new Cfg();
    cfg.prodOpp = 'ART 360';
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso, 'ART 360 fica fora do cálculo jurídico.');
    System.assert(r.mensagem.containsIgnoreCase('ART 360'), r.mensagem);
    System.assertEquals(null, campoData(x.oppId));
  }

  @IsTest
  static void oportunidadeFechada() {
    Cfg cfg = new Cfg();
    cfg.etapaOpp = 'Perdido';
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('fechada'), r.mensagem);
  }

  @IsTest
  static void oportunidadeForaDeDiagnostico() {
    Cfg cfg = new Cfg();
    cfg.etapaOpp = 'Negociação';
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('Diagnóstico'), r.mensagem);
    System.assertEquals(null, campoData(x.oppId));
  }

  @IsTest
  static void oportunidadeSemLeadConvertido() {
    Cfg cfg = new Cfg();
    cfg.comLead = false;
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('Lead convertido'), r.mensagem);
  }

  // ============================================================ PROTEÇÕES DO LEAD

  @IsTest
  static void reuniaoAusente() {
    Cfg cfg = new Cfg();
    cfg.reuniao = false;
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('reunião'), r.mensagem);
    System.assertEquals(null, campoData(x.oppId));
  }

  @IsTest
  static void procuracaoNaoRecebida() {
    Cfg cfg = new Cfg();
    cfg.statusProc = 'Solicitada';
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('procuração ainda não foi recebida'), r.mensagem);
  }

  @IsTest
  static void procuracaoSemDataDeRecebimento() {
    Cfg cfg = new Cfg();
    cfg.dataProc = false;
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('data do recebimento'), r.mensagem);
  }

  @IsTest
  static void documentoAusente() {
    Cfg cfg = new Cfg();
    cfg.docLead = false;
    cfg.docOpp = false;
    Ctx x = montar(cfg);

    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = reg(x.oppId, Date.today());
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('documento da procuração'), r.mensagem);
    System.assertEquals(null, campoData(x.oppId));
  }

  // ============================================================ BULK

  @IsTest
  static void processamentoBulk() {
    List<Id> opps = new List<Id>();
    for (Integer i = 0; i < 4; i++) {
      opps.add(montar(new Cfg()).oppId);
    }
    List<SOLSolicitarCalculoService.Pedido> lote = new List<SOLSolicitarCalculoService.Pedido>();
    for (Id oid : opps) {
      lote.add(new SOLSolicitarCalculoService.Pedido(oid, Date.today()));
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    List<SOLSolicitarCalculoService.Resultado> rs = SOLSolicitarCalculoService.registrar(lote);
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    for (SOLSolicitarCalculoService.Resultado r : rs) {
      System.assert(r.sucesso, r.mensagem);
    }
    System.assertEquals(4, [
      SELECT COUNT()
      FROM Opportunity
      WHERE Id IN :opps AND SOL_Data_Solicitacao_Calculo__c = TODAY
    ]);
    // Inclui as consultas/DML do Flow after-save do CLICKUP-9421 (uma vez para o
    // lote inteiro): 2 Savepoints + 1 update + 1 insert = 4 DML fixos. O ponto
    // do teste é: nada escala por pedido — com 4 Opps, um algoritmo por-registro
    // passaria de 15 SOQL / 8 DML.
    System.assert(soql <= 9, 'SOQL não escala por pedido: ' + soql);
    System.assert(dml <= 5, 'DML não escala por pedido: ' + dml);
    System.assertEquals(
      4,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhatId IN :opps AND SOL_Tipo_Tarefa__c = 'Acompanhamento do cálculo jurídico'
      ],
      'CLICKUP-9421: uma tarefa de acompanhamento por Opp, em lote.'
    );
  }

  @IsTest
  static void loteMisto_soOsElegiveisGravam() {
    Ctx ok = montar(new Cfg());
    Cfg semReuniao = new Cfg();
    semReuniao.reuniao = false;
    Ctx ruim = montar(semReuniao);

    Test.startTest();
    List<SOLSolicitarCalculoService.Resultado> rs = SOLSolicitarCalculoService.registrar(
      new List<SOLSolicitarCalculoService.Pedido>{
        new SOLSolicitarCalculoService.Pedido(ok.oppId, Date.today()),
        new SOLSolicitarCalculoService.Pedido(ruim.oppId, Date.today())
      }
    );
    Test.stopTest();

    System.assert(rs[0].sucesso);
    System.assertEquals(false, rs[1].sucesso);
    System.assertEquals(Date.today(), campoData(ok.oppId));
    System.assertEquals(null, campoData(ruim.oppId));
  }

  // ============================================================ ATOMICIDADE

  @IsTest
  static void falhaTecnicaAbortaAtomicamente() {
    Ctx x = montar(new Cfg());

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      reg(x.oppId, Date.today());
    } catch (SOLSolicitarCalculoService.SolicitacaoCalculoException e) {
      lancou = true;
      System.assertEquals(SOLSolicitarCalculoService.MSG_FALHA, e.getMessage());
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'Falha técnica relança SolicitacaoCalculoException.');
    System.assertEquals(null, campoData(x.oppId), 'Nada gravado — rollback.');
  }

  // ============================================================ SERVIÇO — BORDAS

  @IsTest
  static void colecaoVaziaOuNula() {
    Test.startTest();
    System.assertEquals(
      0,
      SOLSolicitarCalculoService.registrar(null).size()
    );
    System.assertEquals(
      0,
      SOLSolicitarCalculoService.registrar(
          new List<SOLSolicitarCalculoService.Pedido>()
        )
        .size()
    );
    Test.stopTest();
  }

  @IsTest
  static void pedidoSemOportunidade() {
    Test.startTest();
    SOLSolicitarCalculoService.Resultado r = SOLSolicitarCalculoService.registrar(
        new List<SOLSolicitarCalculoService.Pedido>{
          new SOLSolicitarCalculoService.Pedido(null, Date.today())
        }
      )[0];
    Test.stopTest();

    System.assertEquals(false, r.sucesso);
    System.assert(r.mensagem.containsIgnoreCase('não informada'), r.mensagem);
  }

  // ============================================================ INVOCABLE

  @IsTest
  static void invocable_sucesso() {
    Ctx x = montar(new Cfg());
    SOLSolicitarCalculoInvocable.Entrada e = new SOLSolicitarCalculoInvocable.Entrada();
    e.opportunityId = x.oppId;
    e.dataSolicitacao = Date.today();

    Test.startTest();
    List<SOLSolicitarCalculoInvocable.Saida> ss = SOLSolicitarCalculoInvocable.registrar(
      new List<SOLSolicitarCalculoInvocable.Entrada>{ e }
    );
    Test.stopTest();

    System.assertEquals(1, ss.size());
    System.assert(ss[0].sucesso, ss[0].mensagem);
    System.assertEquals(false, ss[0].jaRegistrado);
    System.assertEquals(Date.today(), campoData(x.oppId));
  }

  @IsTest
  static void invocable_mensagemControladaSemGravar() {
    Cfg cfg = new Cfg();
    cfg.prodOpp = 'ART 360';
    Ctx x = montar(cfg);
    SOLSolicitarCalculoInvocable.Entrada e = new SOLSolicitarCalculoInvocable.Entrada();
    e.opportunityId = x.oppId;
    e.dataSolicitacao = Date.today();

    Test.startTest();
    List<SOLSolicitarCalculoInvocable.Saida> ss = SOLSolicitarCalculoInvocable.registrar(
      new List<SOLSolicitarCalculoInvocable.Entrada>{ e }
    );
    Test.stopTest();

    System.assertEquals(false, ss[0].sucesso);
    System.assert(ss[0].mensagem.containsIgnoreCase('ART 360'), ss[0].mensagem);
    System.assertEquals(null, campoData(x.oppId));
  }

  @IsTest
  static void invocable_relancaFalhaTecnica() {
    Ctx x = montar(new Cfg());
    SOLSolicitarCalculoInvocable.Entrada e = new SOLSolicitarCalculoInvocable.Entrada();
    e.opportunityId = x.oppId;
    e.dataSolicitacao = Date.today();

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLSolicitarCalculoInvocable.registrar(
        new List<SOLSolicitarCalculoInvocable.Entrada>{ e }
      );
    } catch (SOLSolicitarCalculoService.SolicitacaoCalculoException ex) {
      lancou = true;
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'O Invocable relança a falha para o Flow abortar a transação.');
    System.assertEquals(null, campoData(x.oppId));
  }

  @IsTest
  static void invocable_entradasInvalidas() {
    Test.startTest();
    System.assertEquals(
      0,
      SOLSolicitarCalculoInvocable.registrar(null).size()
    );
    System.assertEquals(
      0,
      SOLSolicitarCalculoInvocable.registrar(
          new List<SOLSolicitarCalculoInvocable.Entrada>()
        )
        .size()
    );
    SOLSolicitarCalculoInvocable.Entrada semId = new SOLSolicitarCalculoInvocable.Entrada();
    List<SOLSolicitarCalculoInvocable.Saida> ss = SOLSolicitarCalculoInvocable.registrar(
      new List<SOLSolicitarCalculoInvocable.Entrada>{ semId }
    );
    Test.stopTest();

    System.assertEquals(1, ss.size());
    System.assertEquals(false, ss[0].sucesso);
  }

  // ============================================================ VENDEDOR COMERCIAL

  private static Id psSolComercialId() {
    return [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id;
  }

  private static User vendedorComercial() {
    Id perfil = [
      SELECT Id
      FROM Profile
      WHERE UserType = 'Standard'
      ORDER BY Name
      LIMIT 1
    ]
    .Id;
    return new User(
      FirstName = 'SOL',
      LastName = 'Calc Vend',
      Alias = 'solcv',
      Email = 'sol.calc.vend@arnone.invalid',
      Username = 'sol.calc.vend.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9420.test.invalid',
      ProfileId = perfil,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  @IsTest
  static void vendedorComercialRegistra_eCampoEhSomenteLeitura() {
    User v = vendedorComercial();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert v;
      insert new PermissionSetAssignment(
        AssigneeId = v.Id,
        PermissionSetId = psSolComercialId()
      );
    }

    Cfg cfg = new Cfg();
    cfg.oppOwner = v.Id;
    Ctx x = montar(cfg);

    Test.startTest();
    System.runAs(new User(Id = v.Id)) {
      // FLS: o vendedor VÊ o campo, mas não pode editá-lo.
      Schema.DescribeFieldResult f = Opportunity.SOL_Data_Solicitacao_Calculo__c.getDescribe();
      System.assert(f.isAccessible(), 'Vendedor enxerga o campo.');
      System.assert(!f.isUpdateable(), 'Campo é somente leitura para o vendedor.');

      // A ação guiada (serviço escreve o campo em nome dele).
      SOLSolicitarCalculoInvocable.Entrada e = new SOLSolicitarCalculoInvocable.Entrada();
      e.opportunityId = x.oppId;
      e.dataSolicitacao = Date.today();
      List<SOLSolicitarCalculoInvocable.Saida> ss = SOLSolicitarCalculoInvocable.registrar(
        new List<SOLSolicitarCalculoInvocable.Entrada>{ e }
      );
      System.assert(ss[0].sucesso, ss[0].mensagem);
    }
    Test.stopTest();

    System.assertEquals(Date.today(), campoData(x.oppId));
  }

  // ============================================================ CONVERSÃO SOL REAL / REGRESSÃO

  private static Id converterSOLReal(String produto, Boolean comReuniao) {
    Lead l = new Lead(
      RecordTypeId = rtLeadSOL(),
      LastName = 'SOL ' + rnd(),
      Company = 'C',
      CNPJ__c = CNPJ,
      Status = 'Captação - Contato',
      SOL_Produto_Interesse__c = produto
    );
    insert l;
    if (comReuniao) {
      Task t = new Task(
        Subject = 'reunião',
        WhoId = l.Id,
        OwnerId = UserInfo.getUserId(),
        Status = 'Open',
        ActivityDate = Date.today(),
        SOL_Tipo_Tarefa__c = 'Reunião comercial'
      );
      insert t;
      update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada');
    }
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    anexar(l.Id);

    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setDoNotCreateOpportunity(false);
    lc.setOpportunityName('Op SOL ' + rnd());
    lc.setConvertedStatus(convStatus());
    Id oppId = Database.convertLead(lc).getOpportunityId();
    update new Opportunity(
      Id = oppId,
      RecordTypeId = rtOppSOL(),
      SOL_Produto_Negocio__c = produto,
      StageName = 'Diagnóstico'
    );
    return oppId;
  }

  @IsTest
  static void conversaoSOLReal_registraNaOppConvertida() {
    Id oppId;
    Test.startTest();
    oppId = converterSOLReal(PRODUTO, true);
    SOLSolicitarCalculoService.Resultado r = reg(oppId, Date.today());
    Test.stopTest();

    System.assert(r.sucesso, 'Opp SOL convertida de verdade aceita o registro. ' + r.mensagem);
    System.assertEquals(Date.today(), campoData(oppId));
  }

  @IsTest
  static void regressao_9419_conversaoSemReuniaoContinuaBloqueada() {
    Test.startTest();
    Boolean bloqueou = false;
    try {
      converterSOLReal(PRODUTO, false);
    } catch (Exception e) {
      bloqueou = true;
    }
    Test.stopTest();

    System.assert(
      bloqueou,
      'CLICKUP-9419 intacto: sem reunião consolidada a conversão é bloqueada.'
    );
  }
}
