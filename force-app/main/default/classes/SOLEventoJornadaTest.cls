/**
 * CLICKUP-9438 — Testes do livro-razão de reatribuições e perdas da jornada
 * Arnone Soluções (SOL_Evento_Jornada__c + SOLEventoJornadaService).
 *
 * Os Flows da jornada ficam ATIVOS: inserir um Lead SOL já dispara a
 * distribuição, e mudar a Oportunidade para "Perdido" já dispara o Flow
 * SOL_Encerrar_Tarefas_Oportunidade_Perdida com $Record__Prior.StageName. Os
 * testes convivem com a automação real e, quando o objetivo é medir contagem,
 * chamam o serviço direto — a operação é idempotente, então as duas formas
 * convivem.
 *
 * O QUE NÃO ESTÁ AQUI, e por quê: a execução REAL dos dois relatórios fica no
 * E2E `scripts/apex/clickup-9438-e2e-relatorio-reatribuicoes-perdas.apex`. O
 * motor de relatórios não enxerga dados não commitados de uma transação de
 * teste, então rodar o relatório aqui mediria a org, não o cenário — e
 * "inspecionar o XML" já foi proibido neste repositório justamente por não ser
 * validação. O que ESTA classe garante é o insumo: a contagem por motivo, o
 * recorte por período e o percentual, conferidos contra SOQL independente sobre
 * os mesmos registros que o relatório lê.
 */
@IsTest
private class SOLEventoJornadaTest {
  private static final String FILA_SINTETICA = 'RR_Evento_SOL_9438';
  private static final String PRODUTO_RT = 'Recuperação Tributária';
  private static final String PRODUTO_ART = 'ART 360';
  private static final String CNPJ = '11222333000181';
  private static Integer seq = 0;

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ================================================================ helpers

  private static String rnd() {
    seq++;
    return seq + 'x' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
  }

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  /**
   * Perfil STANDARD, e não o do usuário do teste. Um vendedor com perfil de
   * administrador tem "View All Data" e passaria por cima de OWD, CRUD e FLS —
   * os testes de segurança mediriam o privilégio do administrador, não a
   * permissão efetiva do vendedor.
   */
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

  private static Id psSolComercial() {
    return [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'PS_SOL_Comercial'
      LIMIT 1
    ]
    .Id;
  }

  private static User vendedor(String tag) {
    return new User(
      FirstName = 'EJ',
      LastName = 'Vend ' + tag,
      Alias = ('ej' + tag).left(8),
      Email = 'ej.' + tag + '@arnone.invalid',
      Username = 'ej.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9438.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  /**
   * Fila sintética habilitada para Lead, com `qtd` vendedores ativos — todos
   * com PS_SOL_Comercial, como em produção: é o Permission Set que dá ao
   * vendedor da BU acesso à jornada, e sem ele o próprio Lead já seria
   * inacessível para ele.
   */
  private static List<Id> montarFila(Integer qtd) {
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      vs.add(vendedor('a' + i + rnd().left(4)));
    }
    System.runAs(contextoAtual()) {
      insert vs;
      Id ps = psSolComercial();
      List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
      for (User u : vs) {
        psas.add(
          new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps)
        );
      }
      insert psas;
      Group fila = new Group(
        Name = 'RR Evento SOL 9438',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : vs) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = u.Id));
      }
      insert gms;
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    List<Id> ids = new List<Id>();
    for (User u : vs) {
      ids.add(u.Id);
    }
    ids.sort();
    return ids;
  }

  private static Id rtLeadSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id rtOppSOL() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static String statusCache;
  private static String statusLead() {
    if (statusCache == null) {
      List<LeadStatus> p = [
        SELECT MasterLabel
        FROM LeadStatus
        WHERE IsDefault = TRUE
        LIMIT 1
      ];
      statusCache = p.isEmpty()
        ? [SELECT MasterLabel FROM LeadStatus LIMIT 1].MasterLabel
        : p[0].MasterLabel;
    }
    return statusCache;
  }

  /**
   * Lead SOL distribuído pelo Flow ativo. A Task "1ª Ligação" da distribuição
   * inicial é removida para não interferir na contagem de tentativas.
   */
  private static Lead leadDistribuido(String produto) {
    Lead l = new Lead(
      RecordTypeId = rtLeadSOL(),
      LastName = 'L' + rnd().left(6),
      Company = 'C ' + rnd().left(6),
      Status = statusLead(),
      CNPJ__c = CNPJ,
      SOL_Produto_Interesse__c = produto
    );
    insert l;
    delete [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação'];
    return lead(l.Id);
  }

  private static Lead leadOutraBU(String nome) {
    Lead l = new Lead(
      LastName = nome,
      Company = 'C ' + rnd().left(6),
      Status = statusLead()
    );
    insert l;
    return lead(l.Id);
  }

  /**
   * `RecordType.DeveloperName` e `SOL_Produto_Interesse__c` fazem parte da
   * projeção porque os construtores de `SOLEventoJornadaService` os leem
   * diretamente — e estouram `SObjectException` se faltarem, de propósito:
   * evento sem Record Type sairia do filtro travado do relatório em silêncio.
   */
  private static Lead lead(Id id) {
    return [
      SELECT
        Id,
        OwnerId,
        Status,
        RecordType.DeveloperName,
        SOL_Opt_Out__c,
        SOL_Quantidade_Reatribuicoes__c,
        SOL_Motivo_Desqualificacao__c,
        SOL_Produto_Interesse__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  /**
   * Abre o ciclo de contato um minuto atrás.
   *
   * POR QUÊ: ao reatribuir, o serviço reinicia o ciclo em
   * `ultimaConclusaoContada + 1s`, justamente para as tarefas que dispararam a
   * troca não voltarem a contar. Numa transação rápida, as tarefas da RODADA
   * SEGUINTE são concluídas dentro desse mesmo segundo e caem ANTES do novo
   * ciclo — a 2ª reatribuição simplesmente não acontece, e o teste passa ou
   * falha conforme a máquina esteja mais rápida ou mais lenta. Foi exatamente
   * assim que estes dois testes passaram em execução síncrona e falharam na
   * execução paralela do deploy.
   *
   * Antecipar o início do ciclo elimina a corrida sem mascarar nada: o que
   * estes testes medem é a OCORRÊNCIA gravada, não a régua de contagem de
   * tentativas — essa tem testes próprios em SOLReatribuicaoContatoServiceTest.
   */
  private static void abrirCicloUmMinutoAtras(Id leadId) {
    update new Lead(
      Id = leadId,
      SOL_Data_Inicio_Ciclo_Contato__c = System.now().addMinutes(-1)
    );
  }

  private static void tentativasNegativas(Id leadId, Integer qtd) {
    List<Task> ts = new List<Task>();
    for (Integer i = 0; i < qtd; i++) {
      ts.add(
        new Task(
          WhoId = leadId,
          Subject = 'Tentativa de contato',
          Status = 'Completed',
          ActivityDate = Date.today(),
          SOL_Resultado_Contato__c = 'Não atendeu'
        )
      );
    }
    insert ts;
  }

  private static Id novaOpp(
    String produto,
    Boolean oppSOL,
    Id owner,
    Datetime inicio,
    Datetime prazo,
    String etapaFinal
  ) {
    Account a = new Account(Name = 'Conta ' + rnd().left(8));
    insert a;
    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd().left(8),
      AccountId = a.Id,
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
    if (oppSOL) {
      o.RecordTypeId = rtOppSOL();
    }
    if (owner != null) {
      o.OwnerId = owner;
    }
    if (inicio != null) {
      o.SOL_Data_Inicio_Ciclo_Comercial__c = inicio;
    }
    if (prazo != null) {
      o.SOL_Prazo_Total_Comercial__c = prazo;
    }
    insert o;
    if (etapaFinal != null && etapaFinal != 'Diagnóstico') {
      update new Opportunity(Id = o.Id, StageName = 'Negociação');
      if (etapaFinal != 'Negociação') {
        Opportunity fecha = new Opportunity(Id = o.Id, StageName = etapaFinal);
        if (etapaFinal == 'Perdido') {
          fecha.SOL_Motivo_Perda__c = 'Sem retorno';
        }
        update fecha;
      }
    }
    return o.Id;
  }

  /** Oportunidade SOL aberta e com prazo total já vencido. */
  private static Id oppVencida(String produto, Id owner) {
    return novaOpp(
      produto,
      true,
      owner,
      Datetime.now().addDays(-60),
      Datetime.now().addDays(-1),
      null
    );
  }

  private static Opportunity opp(Id id) {
    return [
      SELECT
        Id,
        OwnerId,
        StageName,
        SOL_Qtd_Reatribuicoes_Prazo__c,
        SOL_Qtd_Perdas__c
      FROM Opportunity
      WHERE Id = :id
    ];
  }

  private static void perder(Id oppId) {
    update new Opportunity(
      Id = oppId,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
  }

  private static void reabrir(Id oppId, String etapa) {
    update new Opportunity(
      Id = oppId,
      StageName = etapa,
      SOL_Motivo_Perda__c = null
    );
  }

  /**
   * Reprocessa a perda pelo mesmo caminho que a automação usa, SEM nova
   * transição: a Oportunidade já está em "Perdido" e nada muda de etapa.
   */
  private static void reprocessarPerda(Id oppId, String etapaAnterior) {
    SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
      new List<Id>{ oppId },
      new Map<Id, String>{ oppId => etapaAnterior }
    );
  }

  private static List<SOL_Evento_Jornada__c> eventos() {
    return [
      SELECT
        Id,
        OwnerId,
        SOL_Tipo_Evento__c,
        SOL_Motivo__c,
        SOL_Origem__c,
        SOL_Data_Ocorrencia__c,
        SOL_Lead__c,
        SOL_Oportunidade__c,
        SOL_Vendedor__c,
        SOL_Novo_Vendedor__c,
        SOL_Etapa_Anterior__c,
        SOL_Produto__c,
        SOL_Record_Type_Origem__c,
        SOL_Sequencia__c,
        SOL_Chave_Idempotencia__c
      FROM SOL_Evento_Jornada__c
      ORDER BY SOL_Sequencia__c ASC, SOL_Chave_Idempotencia__c ASC
    ];
  }

  private static List<SOL_Evento_Jornada__c> eventosDoLead(Id leadId) {
    return [
      SELECT
        Id,
        OwnerId,
        SOL_Motivo__c,
        SOL_Tipo_Evento__c,
        SOL_Origem__c,
        SOL_Vendedor__c,
        SOL_Novo_Vendedor__c,
        SOL_Produto__c,
        SOL_Record_Type_Origem__c,
        SOL_Sequencia__c,
        SOL_Chave_Idempotencia__c,
        SOL_Data_Ocorrencia__c
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Lead__c = :leadId
      ORDER BY SOL_Sequencia__c ASC
    ];
  }

  private static List<SOL_Evento_Jornada__c> eventosDaOpp(Id oppId) {
    return [
      SELECT
        Id,
        OwnerId,
        SOL_Motivo__c,
        SOL_Tipo_Evento__c,
        SOL_Origem__c,
        SOL_Vendedor__c,
        SOL_Novo_Vendedor__c,
        SOL_Etapa_Anterior__c,
        SOL_Produto__c,
        SOL_Record_Type_Origem__c,
        SOL_Sequencia__c,
        SOL_Chave_Idempotencia__c,
        SOL_Data_Ocorrencia__c
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Oportunidade__c = :oppId
      ORDER BY SOL_Sequencia__c ASC
    ];
  }

  private static Integer totalEventos() {
    return [SELECT COUNT() FROM SOL_Evento_Jornada__c];
  }

  // ==================================================== 1. OS QUATRO MOTIVOS

  /**
   * (1a) Reatribuição por falta de contato: uma ocorrência, com o vendedor
   * ANTERIOR e o NOVO corretos. O Owner atual do Lead responde só "quem tem
   * agora"; o par de origem/destino só existe aqui.
   */
  @IsTest
  static void reatribuicaoPorFaltaDeContatoGeraOcorrencia() {
    List<Id> vs = montarFila(3);
    Lead l = leadDistribuido(PRODUTO_RT);
    Id anterior = l.OwnerId;

    Test.startTest();
    tentativasNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead depois = lead(l.Id);
    List<SOL_Evento_Jornada__c> evs = eventosDoLead(l.Id);
    System.assertEquals(1, evs.size(), 'Uma reatribuição, uma ocorrência.');
    SOL_Evento_Jornada__c e = evs[0];
    System.assertEquals(
      SOLEventoJornadaService.MOTIVO_FALTA_CONTATO,
      e.SOL_Motivo__c,
      'Motivo da ocorrência.'
    );
    System.assertEquals(
      SOLEventoJornadaService.TIPO_REATRIBUICAO,
      e.SOL_Tipo_Evento__c
    );
    System.assertEquals(SOLEventoJornadaService.ORIGEM_LEAD, e.SOL_Origem__c);
    System.assertEquals(
      anterior,
      e.SOL_Vendedor__c,
      'Vendedor ANTERIOR, capturado antes de o OwnerId ser sobrescrito.'
    );
    System.assertEquals(
      depois.OwnerId,
      e.SOL_Novo_Vendedor__c,
      'Novo vendedor igual ao proprietário atual do Lead.'
    );
    System.assertNotEquals(
      e.SOL_Vendedor__c,
      e.SOL_Novo_Vendedor__c,
      'Reatribuição troca de vendedor.'
    );
    System.assertEquals(PRODUTO_RT, e.SOL_Produto__c, 'Produto congelado.');
    System.assertEquals('SOL', e.SOL_Record_Type_Origem__c);
    System.assertEquals(1, e.SOL_Sequencia__c, 'Primeira reatribuição.');
    System.assertNotEquals(null, e.SOL_Data_Ocorrencia__c);
    System.assertEquals(
      anterior,
      e.OwnerId,
      'Proprietário do evento = vendedor responsável no instante da ocorrência.'
    );
    System.assertEquals(
      'FC|' + String.valueOf(l.Id) + '|1',
      e.SOL_Chave_Idempotencia__c,
      'Chave determinística da ocorrência.'
    );
  }

  /**
   * (1b) Reatribuição por estouro do prazo total: mesma prova do par
   * origem/destino, agora na Oportunidade e com o produto ART 360.
   */
  @IsTest
  static void reatribuicaoPorPrazoTotalGeraOcorrencia() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_ART, vs[0]);

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(1, r.reatribuidas, 'A Oportunidade foi reatribuída.');
    Opportunity depois = opp(oppId);
    List<SOL_Evento_Jornada__c> evs = eventosDaOpp(oppId);
    System.assertEquals(1, evs.size(), 'Uma reatribuição, uma ocorrência.');
    SOL_Evento_Jornada__c e = evs[0];
    System.assertEquals(
      SOLEventoJornadaService.MOTIVO_PRAZO_TOTAL,
      e.SOL_Motivo__c
    );
    System.assertEquals(
      SOLEventoJornadaService.TIPO_REATRIBUICAO,
      e.SOL_Tipo_Evento__c
    );
    System.assertEquals(
      SOLEventoJornadaService.ORIGEM_OPORTUNIDADE,
      e.SOL_Origem__c
    );
    System.assertEquals(vs[0], e.SOL_Vendedor__c, 'Vendedor anterior.');
    System.assertEquals(depois.OwnerId, e.SOL_Novo_Vendedor__c, 'Novo vendedor.');
    System.assertEquals(PRODUTO_ART, e.SOL_Produto__c, 'ART 360 é contemplado.');
    System.assertEquals('SOL', e.SOL_Record_Type_Origem__c);
    System.assertEquals(1, e.SOL_Sequencia__c);
    System.assertEquals(
      null,
      e.SOL_Etapa_Anterior__c,
      'Etapa anterior é exclusiva da perda de Oportunidade.'
    );
    System.assertEquals(
      'PT|' + String.valueOf(oppId) + '|1',
      e.SOL_Chave_Idempotencia__c
    );
  }

  /** (1c) Lead perdido por opt-out: perda, sem novo vendedor. */
  @IsTest
  static void optOutGeraOcorrenciaDeLeadPerdido() {
    montarFila(2);
    Lead l = leadDistribuido(PRODUTO_ART);
    Id dono = l.OwnerId;

    Test.startTest();
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    Test.stopTest();

    List<SOL_Evento_Jornada__c> evs = eventosDoLead(l.Id);
    System.assertEquals(1, evs.size(), 'Um opt-out, uma ocorrência.');
    SOL_Evento_Jornada__c e = evs[0];
    System.assertEquals(SOLEventoJornadaService.MOTIVO_OPT_OUT, e.SOL_Motivo__c);
    System.assertEquals(
      SOLEventoJornadaService.TIPO_PERDA,
      e.SOL_Tipo_Evento__c,
      'Opt-out é perda, não reatribuição.'
    );
    System.assertEquals(dono, e.SOL_Vendedor__c, 'Vendedor responsável.');
    System.assertEquals(
      null,
      e.SOL_Novo_Vendedor__c,
      'Perda não tem novo vendedor.'
    );
    System.assertEquals(PRODUTO_ART, e.SOL_Produto__c);
    System.assertEquals('SOL', e.SOL_Record_Type_Origem__c);
    System.assertEquals(
      'OO|' + String.valueOf(l.Id),
      e.SOL_Chave_Idempotencia__c,
      'Opt-out é único e definitivo por Lead: chave sem discriminador.'
    );
    System.assertEquals(true, lead(l.Id).SOL_Opt_Out__c);
  }

  /**
   * (1d) Oportunidade perdida: a ocorrência guarda a etapa REAL de origem, pelo
   * caminho de produção — a transição dispara o Flow, que envia
   * $Record__Prior.StageName.
   */
  @IsTest
  static void oportunidadePerdidaGravaEtapaAnteriorReal() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');

    Test.startTest();
    update new Opportunity(
      Id = oppId,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    Test.stopTest();

    List<SOL_Evento_Jornada__c> evs = eventosDaOpp(oppId);
    System.assertEquals(1, evs.size(), 'Uma perda, uma ocorrência.');
    SOL_Evento_Jornada__c e = evs[0];
    System.assertEquals(
      SOLEventoJornadaService.MOTIVO_OPORTUNIDADE_PERDIDA,
      e.SOL_Motivo__c
    );
    System.assertEquals(SOLEventoJornadaService.TIPO_PERDA, e.SOL_Tipo_Evento__c);
    System.assertEquals(
      'Negociação',
      e.SOL_Etapa_Anterior__c,
      'Etapa de ORIGEM da perda, não o destino.'
    );
    System.assertNotEquals(
      SOLEventoJornadaService.ETAPA_PERDIDO,
      e.SOL_Etapa_Anterior__c,
      '"Perdido" nunca pode ser gravado como etapa anterior.'
    );
    System.assertEquals(vs[0], e.SOL_Vendedor__c);
    System.assertEquals(null, e.SOL_Novo_Vendedor__c);
    System.assertEquals(PRODUTO_RT, e.SOL_Produto__c);
    System.assertEquals(
      1,
      e.SOL_Sequencia__c,
      'Primeira transição desta Oportunidade para "Perdido".'
    );
    System.assertEquals(
      'OP|' + String.valueOf(oppId) + '|1',
      e.SOL_Chave_Idempotencia__c,
      'A chave identifica a TRANSIÇÃO, não a etapa de origem.'
    );
    System.assertEquals(
      1,
      opp(oppId).SOL_Qtd_Perdas__c,
      'O contador de transições foi carimbado pelo Flow before-save.'
    );
  }

  /** (1e) A etapa anterior acompanha a etapa real: perda saindo de Fechamento. */
  @IsTest
  static void perdaDeFechamentoGravaFechamentoComoEtapaAnterior() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_ART, true, vs[0], null, null, 'Fechamento');

    Test.startTest();
    update new Opportunity(
      Id = oppId,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    Test.stopTest();

    List<SOL_Evento_Jornada__c> evs = eventosDaOpp(oppId);
    System.assertEquals(1, evs.size());
    System.assertEquals(
      'Fechamento',
      evs[0].SOL_Etapa_Anterior__c,
      'A segmentação da perda acompanha a etapa real de origem.'
    );
    System.assertEquals(PRODUTO_ART, evs[0].SOL_Produto__c);
  }

  // ============ 1bis. A PERDA É IDENTIFICADA PELA TRANSIÇÃO, NÃO PELO ESTADO

  /**
   * (1f) A narrativa inteira, na ordem em que acontece na vida real:
   *   1. a Oportunidade é perdida            -> 1 ocorrência
   *   2. reprocessa SEM nova transição       -> continua 1
   *   3. reabre
   *   4. perde de novo, da MESMA etapa       -> 2 ocorrências
   *   5. reprocessa a segunda perda          -> continua 2
   *
   * O passo 4 é o ponto do card: uma segunda transição REAL é ocorrência nova
   * mesmo partindo da mesma etapa. Quem separa os passos 2 e 4 é o contador de
   * transições — nenhum timestamp da plataforma consegue, porque
   * LastStageChangeDate/LastModifiedDate/SystemModstamp têm precisão de segundo
   * e a reabertura e a segunda perda caem no mesmo segundo aqui dentro.
   */
  @IsTest
  static void perdaReabreEPerdeDeNovoNaMesmaEtapaContaDuasVezes() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');

    Test.startTest();
    // [1] primeira perda
    perder(oppId);
    List<SOL_Evento_Jornada__c> apos1 = eventosDaOpp(oppId);
    Datetime ocorrencia1 = apos1.isEmpty() ? null : apos1[0].SOL_Data_Ocorrencia__c;

    // [2] reprocessa sem transição — duas vezes, para não sobrar dúvida
    reprocessarPerda(oppId, 'Negociação');
    reprocessarPerda(oppId, 'Negociação');
    List<SOL_Evento_Jornada__c> apos2 = eventosDaOpp(oppId);

    // [3] reabre e [4] perde de novo, DA MESMA ETAPA
    reabrir(oppId, 'Negociação');
    perder(oppId);
    List<SOL_Evento_Jornada__c> apos4 = eventosDaOpp(oppId);

    // [5] reprocessa a segunda perda
    reprocessarPerda(oppId, 'Negociação');
    List<SOL_Evento_Jornada__c> apos5 = eventosDaOpp(oppId);
    Test.stopTest();

    System.assertEquals(1, apos1.size(), '[1] a perda gera UMA ocorrência.');
    System.assertEquals(
      1,
      apos2.size(),
      '[2] reprocessar sem nova transição não duplica.'
    );
    System.assertEquals(
      ocorrencia1,
      apos2[0].SOL_Data_Ocorrencia__c,
      '[2] e não reescreve a ocorrência original.'
    );
    System.assertEquals(
      2,
      apos4.size(),
      '[4] a segunda perda REAL, da mesma etapa, é ocorrência nova.'
    );
    System.assertEquals(
      2,
      apos5.size(),
      '[5] reprocessar a segunda perda também não duplica.'
    );

    System.assertEquals(1, apos5[0].SOL_Sequencia__c);
    System.assertEquals(2, apos5[1].SOL_Sequencia__c);
    System.assertEquals(
      'OP|' + String.valueOf(oppId) + '|1',
      apos5[0].SOL_Chave_Idempotencia__c
    );
    System.assertEquals(
      'OP|' + String.valueOf(oppId) + '|2',
      apos5[1].SOL_Chave_Idempotencia__c,
      'Chaves distintas para transições distintas.'
    );
    System.assertEquals(
      'Negociação',
      apos5[0].SOL_Etapa_Anterior__c,
      'As duas perdas saíram da MESMA etapa — e ainda assim são duas linhas.'
    );
    System.assertEquals('Negociação', apos5[1].SOL_Etapa_Anterior__c);
    System.assertEquals(
      2,
      opp(oppId).SOL_Qtd_Perdas__c,
      'O contador de transições acompanha as duas perdas.'
    );
  }

  /**
   * (1g) Lote com perdas distintas não colide: cada Oportunidade tem o seu
   * próprio contador, e a chave carrega o Id.
   */
  @IsTest
  static void loteDePerdasDistintasNaoColide() {
    List<Id> vs = montarFila(2);
    List<Id> opps = new List<Id>();
    for (Integer i = 0; i < 6; i++) {
      opps.add(
        novaOpp(
          Math.mod(i, 2) == 0 ? PRODUTO_RT : PRODUTO_ART,
          true,
          vs[0],
          null,
          null,
          Math.mod(i, 2) == 0 ? 'Negociação' : 'Fechamento'
        )
      );
    }

    Test.startTest();
    List<Opportunity> perdas = new List<Opportunity>();
    for (Id oppId : opps) {
      perdas.add(
        new Opportunity(
          Id = oppId,
          StageName = 'Perdido',
          SOL_Motivo_Perda__c = 'Sem retorno'
        )
      );
    }
    update perdas;
    Test.stopTest();

    List<SOL_Evento_Jornada__c> evs = eventos();
    System.assertEquals(6, evs.size(), 'Seis perdas, seis ocorrências.');
    Set<String> chaves = new Set<String>();
    Set<Id> oppsVistas = new Set<Id>();
    for (SOL_Evento_Jornada__c e : evs) {
      chaves.add(e.SOL_Chave_Idempotencia__c);
      oppsVistas.add(e.SOL_Oportunidade__c);
      System.assertEquals(
        1,
        e.SOL_Sequencia__c,
        'Cada Oportunidade está na sua primeira perda.'
      );
    }
    System.assertEquals(6, chaves.size(), 'Seis chaves distintas.');
    System.assertEquals(6, oppsVistas.size(), 'Uma ocorrência por Oportunidade.');
  }

  /**
   * (1h) Concorrência na perda, nos limites testáveis em Apex: mesmo que duas
   * transações simultâneas passem pelo filtro de chaves existentes, o índice
   * ÚNICO recusa a segunda linha da MESMA transição.
   */
  @IsTest
  static void indiceUnicoRecusaSegundaLinhaDaMesmaPerda() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');
    perder(oppId);

    Test.startTest();
    Boolean recusou = false;
    String codigo = null;
    try {
      insert new SOL_Evento_Jornada__c(
        SOL_Tipo_Evento__c = SOLEventoJornadaService.TIPO_PERDA,
        SOL_Motivo__c = SOLEventoJornadaService.MOTIVO_OPORTUNIDADE_PERDIDA,
        SOL_Origem__c = SOLEventoJornadaService.ORIGEM_OPORTUNIDADE,
        SOL_Data_Ocorrencia__c = System.now(),
        SOL_Sequencia__c = 1,
        SOL_Oportunidade__c = oppId,
        SOL_Etapa_Anterior__c = 'Negociação',
        SOL_Record_Type_Origem__c = 'SOL',
        SOL_Chave_Idempotencia__c = 'OP|' + String.valueOf(oppId) + '|1'
      );
    } catch (DmlException e) {
      recusou = true;
      codigo = String.valueOf(e.getDmlType(0));
    }
    Test.stopTest();

    System.assert(recusou, 'A duplicata da mesma transição é recusada.');
    System.assertEquals(String.valueOf(StatusCode.DUPLICATE_VALUE), codigo);
    System.assertEquals(1, eventosDaOpp(oppId).size());
  }

  /**
   * (1i) Perda sem o carimbo da transição ABORTA. Sem o contador não há como
   * separar reprocessamento de nova perda, e as duas respostas erradas custam
   * caro: ou some uma ocorrência, ou nasce uma duplicada.
   */
  @IsTest
  static void perdaSemCarimboDaTransicaoAborta() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');
    perder(oppId);
    delete [SELECT Id FROM SOL_Evento_Jornada__c];
    // Simula o registro que nunca passou pelo Flow before-save (dado anterior à
    // implantação, ou carga que desligou automações).
    update new Opportunity(Id = oppId, SOL_Qtd_Perdas__c = null);
    Task t = new Task(
      WhatId = oppId,
      Subject = 'Aberta',
      OwnerId = vs[0],
      Status = 'Open',
      ActivityDate = Date.today()
    );
    insert t;

    Test.startTest();
    String mensagem = null;
    try {
      reprocessarPerda(oppId, 'Negociação');
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      mensagem = e.getMessage();
    }
    Test.stopTest();

    System.assertEquals(
      SOLNegocioPerdidoService.MSG_TRANSICAO_NAO_CARIMBADA,
      mensagem,
      'Aborta com mensagem própria, sem detalhe técnico.'
    );
    System.assertEquals(0, totalEventos(), 'Nenhuma ocorrência sem identidade.');
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :t.Id].Status,
      'E a operação de negócio foi desfeita junto.'
    );
  }

  // ============================== 2. MÚLTIPLAS OCORRÊNCIAS DO MESMO REGISTRO

  /**
   * (2) Duas reatribuições legítimas do MESMO Lead geram DUAS ocorrências, com
   * sequência e vendedores encadeados. É exatamente o que o contador acumulado
   * `SOL_Quantidade_Reatribuicoes__c` não sabe responder.
   */
  @IsTest
  static void reatribuicoesSucessivasGeramOcorrenciasDistintas() {
    List<Id> vs = montarFila(3);
    Lead l = leadDistribuido(PRODUTO_RT);
    Id vendedor1 = l.OwnerId;

    Test.startTest();
    tentativasNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Id vendedor2 = lead(l.Id).OwnerId;

    abrirCicloUmMinutoAtras(l.Id);
    tentativasNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Id vendedor3 = lead(l.Id).OwnerId;
    List<SOL_Evento_Jornada__c> evs = eventosDoLead(l.Id);
    System.assertEquals(2, evs.size(), 'Duas reatribuições, duas ocorrências.');
    System.assertEquals(1, evs[0].SOL_Sequencia__c);
    System.assertEquals(2, evs[1].SOL_Sequencia__c);
    System.assertEquals(vendedor1, evs[0].SOL_Vendedor__c);
    System.assertEquals(vendedor2, evs[0].SOL_Novo_Vendedor__c);
    System.assertEquals(
      vendedor2,
      evs[1].SOL_Vendedor__c,
      'A 2ª ocorrência começa onde a 1ª terminou.'
    );
    System.assertEquals(vendedor3, evs[1].SOL_Novo_Vendedor__c);
    System.assertNotEquals(
      evs[0].SOL_Chave_Idempotencia__c,
      evs[1].SOL_Chave_Idempotencia__c,
      'Ocorrências legítimas diferentes têm chaves diferentes.'
    );
    System.assertEquals(
      2,
      lead(l.Id).SOL_Quantidade_Reatribuicoes__c,
      'O contador acumulado bate com a quantidade de ocorrências.'
    );
  }

  // ==================================== 3. REPROCESSAMENTO SEM DUPLICIDADE

  /**
   * (3a) Reprocessar a avaliação de reatribuição não duplica: o ciclo foi
   * reiniciado, então não há segunda reatribuição — e nenhuma ocorrência nova.
   */
  @IsTest
  static void reprocessarReatribuicaoNaoDuplicaOcorrencia() {
    montarFila(3);
    Lead l = leadDistribuido(PRODUTO_RT);

    Test.startTest();
    tentativasNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertEquals(
      1,
      eventosDoLead(l.Id).size(),
      'Três passadas, uma ocorrência.'
    );
  }

  /**
   * (3b) A chave é a rede final: reapresentar o MESMO evento ao serviço não
   * grava nada, e o registro já existente permanece intocado.
   */
  @IsTest
  static void registrarMesmaChaveDuasVezesNaoDuplica() {
    montarFila(2);
    Lead l = leadDistribuido(PRODUTO_RT);
    Datetime agora = System.now();

    Test.startTest();
    Integer primeiro = SOLEventoJornadaService.registrar(
      new List<SOL_Evento_Jornada__c>{
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          1,
          agora
        )
      }
    );
    // Mesma ocorrência, outra transação lógica.
    Integer segundo = SOLEventoJornadaService.registrar(
      new List<SOL_Evento_Jornada__c>{
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          1,
          agora.addHours(2)
        )
      }
    );
    // E a mesma chave DUAS vezes dentro do MESMO lote.
    Integer terceiro = SOLEventoJornadaService.registrar(
      new List<SOL_Evento_Jornada__c>{
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          2,
          agora
        ),
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          2,
          agora
        )
      }
    );
    Test.stopTest();

    System.assertEquals(1, primeiro, 'A 1ª gravação entra.');
    System.assertEquals(0, segundo, 'A repetição não entra.');
    System.assertEquals(
      1,
      terceiro,
      'A mesma chave duas vezes no mesmo lote vira uma ocorrência.'
    );
    List<SOL_Evento_Jornada__c> evs = eventosDoLead(l.Id);
    System.assertEquals(2, evs.size(), 'Sequências 1 e 2, sem duplicata.');
    System.assertEquals(
      agora,
      evs[0].SOL_Data_Ocorrencia__c,
      'A ocorrência original NÃO é sobrescrita pelo reprocessamento.'
    );
  }

  /** (3c) Opt-out repetido não gera segunda ocorrência. */
  @IsTest
  static void optOutRepetidoNaoDuplicaOcorrencia() {
    montarFila(2);
    Lead l = leadDistribuido(PRODUTO_RT);

    Test.startTest();
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertEquals(1, eventosDoLead(l.Id).size());
  }

  /**
   * (3d) CONCORRÊNCIA, nos limites testáveis em Apex: mesmo que o filtro por
   * chave existente seja vencido por uma transação simultânea, o índice ÚNICO
   * do banco recusa a segunda linha. É a garantia que não depende de timing.
   */
  @IsTest
  static void indiceUnicoRecusaSegundaLinhaComAMesmaChave() {
    montarFila(2);
    Lead l = leadDistribuido(PRODUTO_RT);
    Datetime agora = System.now();
    SOLEventoJornadaService.registrar(
      new List<SOL_Evento_Jornada__c>{
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          1,
          agora
        )
      }
    );

    Test.startTest();
    Boolean recusou = false;
    String codigo = null;
    try {
      // Insert DIRETO, sem passar pelo filtro do serviço: simula a corrida.
      insert new SOL_Evento_Jornada__c(
        SOL_Tipo_Evento__c = SOLEventoJornadaService.TIPO_REATRIBUICAO,
        SOL_Motivo__c = SOLEventoJornadaService.MOTIVO_FALTA_CONTATO,
        SOL_Origem__c = SOLEventoJornadaService.ORIGEM_LEAD,
        SOL_Data_Ocorrencia__c = agora,
        SOL_Sequencia__c = 1,
        SOL_Lead__c = l.Id,
        SOL_Record_Type_Origem__c = 'SOL',
        SOL_Chave_Idempotencia__c = 'FC|' + String.valueOf(l.Id) + '|1'
      );
    } catch (DmlException e) {
      recusou = true;
      codigo = String.valueOf(e.getDmlType(0));
    }
    Test.stopTest();

    System.assert(recusou, 'O índice único recusa a duplicata.');
    System.assertEquals(
      String.valueOf(StatusCode.DUPLICATE_VALUE),
      codigo,
      'A recusa vem do índice único, não de validação de aplicação.'
    );
    System.assertEquals(1, eventosDoLead(l.Id).size());
  }

  // =================================================================== 4. LOTE

  /**
   * (4a) Lote de Leads: uma ocorrência por reatribuição, sem SOQL/DML em laço.
   * O custo do registro é FIXO — não cresce com o tamanho do lote.
   */
  @IsTest
  static void loteDeReatribuicoesGeraUmaOcorrenciaPorLead() {
    montarFila(3);
    // Um único insert para os 25 Leads: a distribuição roda em bulk, como em
    // produção. Inserir um a um estouraria o limite de consultas ANTES do que
    // este teste quer medir.
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 25; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rtLeadSOL(),
          LastName = 'B' + i + rnd().left(4),
          Company = 'C ' + i,
          Status = statusLead(),
          CNPJ__c = CNPJ,
          SOL_Produto_Interesse__c = Math.mod(i, 2) == 0
            ? PRODUTO_RT
            : PRODUTO_ART
        )
      );
    }
    insert leads;
    List<Id> leadIds = new List<Id>();
    for (Lead l : leads) {
      leadIds.add(l.Id);
    }
    delete [
      SELECT Id
      FROM Task
      WHERE WhoId IN :leadIds AND Subject = '1ª Ligação'
    ];

    List<Task> tarefas = new List<Task>();
    for (Id leadId : leadIds) {
      for (Integer k = 0; k < 3; k++) {
        tarefas.add(
          new Task(
            WhoId = leadId,
            Subject = 'Tentativa',
            Status = 'Completed',
            ActivityDate = Date.today(),
            SOL_Resultado_Contato__c = 'Não atendeu'
          )
        );
      }
    }
    insert tarefas;
    // O Flow SOL_Reatribuir_Por_Falta_Contato já reatribuiu na inserção das
    // tarefas; a chamada abaixo é o 2º passe, que precisa ser inócuo.
    Integer jaGravados = totalEventos();

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(leadIds);
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(
      25,
      jaGravados,
      'A reatribuição em bulk gerou uma ocorrência por Lead.'
    );
    System.assertEquals(
      25,
      totalEventos(),
      'O 2º passe sobre os mesmos 25 Leads não acrescentou ocorrência.'
    );
    System.assert(soql <= 10, 'Custo de SOQL fixo, não por Lead: ' + soql);
    System.assert(dml <= 6, 'Custo de DML fixo, não por Lead: ' + dml);

    Map<Id, SOL_Evento_Jornada__c> porLead = new Map<Id, SOL_Evento_Jornada__c>();
    for (SOL_Evento_Jornada__c e : eventos()) {
      System.assertEquals(
        false,
        porLead.containsKey(e.SOL_Lead__c),
        'Nenhum Lead aparece duas vezes.'
      );
      System.assertNotEquals(
        null,
        e.SOL_Vendedor__c,
        'Toda ocorrência do lote tem vendedor anterior.'
      );
      System.assertNotEquals(
        e.SOL_Vendedor__c,
        e.SOL_Novo_Vendedor__c,
        'E um vendedor de destino diferente.'
      );
      System.assertEquals(1, e.SOL_Sequencia__c);
      porLead.put(e.SOL_Lead__c, e);
    }
    System.assertEquals(25, porLead.size());
    System.assertEquals(
      25,
      new Set<Id>(leadIds).size(),
      'Os 25 Leads do lote estão representados.'
    );
    for (Id leadId : leadIds) {
      System.assert(
        porLead.containsKey(leadId),
        'Nenhum Lead do lote ficou sem ocorrência: ' + leadId
      );
    }
  }

  /**
   * (4b) Lote grande direto no serviço de registro: 200 ocorrências novas com o
   * mesmo número de consultas e gravações de uma só.
   */
  @IsTest
  static void registrarLoteDe200MantemCustoConstante() {
    montarFila(2);
    Lead l = leadDistribuido(PRODUTO_RT);
    Datetime agora = System.now();
    List<SOL_Evento_Jornada__c> lote = new List<SOL_Evento_Jornada__c>();
    for (Integer i = 1; i <= 200; i++) {
      lote.add(
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          i,
          agora
        )
      );
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    Integer gravados = SOLEventoJornadaService.registrar(lote);
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(200, gravados, 'As 200 ocorrências entram.');
    System.assertEquals(2, soql, 'Duas consultas: chaves existentes e usuários.');
    System.assertEquals(1, dml, 'Uma única gravação.');
  }

  // ==================================================== 5. ISOLAMENTO DE BUs

  /**
   * (5) Outras BUs não produzem ocorrência: Lead sem Record Type SOL e
   * Oportunidade fora dos dois produtos passam pelos serviços e são ignorados.
   */
  @IsTest
  static void outrasBUsNaoGeramOcorrencia() {
    List<Id> vs = montarFila(2);
    Lead outro = leadOutraBU('ForaDaBU');
    Id oppOutraBU = novaOpp(PRODUTO_RT, false, vs[0], null, null, 'Negociação');
    Id oppSemProduto = novaOpp(null, true, vs[0], null, null, 'Negociação');

    Test.startTest();
    tentativasNegativas(outro.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ outro.Id });
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ outro.Id });
    update new Opportunity(
      Id = oppOutraBU,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    update new Opportunity(
      Id = oppSemProduto,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    Test.stopTest();

    System.assertEquals(
      0,
      totalEventos(),
      'Nenhuma ocorrência fora da Arnone Soluções.'
    );
  }

  /**
   * (5b) O vetor que o recorte por produto sozinho deixava aberto: uma
   * Oportunidade de OUTRA BU, atualizada por API com um produto SOL, e perdida
   * pelo processo daquela BU.
   *
   * O Flow before-save exige as TRÊS condições juntas — Record Type SOL,
   * produto no escopo e transição real. Sem a checagem de Record Type, esta
   * Oportunidade incrementaria `SOL_Qtd_Perdas__c` de outra unidade.
   */
  @IsTest
  static void outraBUComProdutoSolNaoIncrementaNemRegistra() {
    montarFila(2);
    Id rtOutraBU = Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('STE_Telecom')
      .getRecordTypeId();
    Account a = new Account(Name = 'Conta outra BU ' + rnd().left(8));
    insert a;
    Opportunity outraBU = new Opportunity(
      Name = 'Op outra BU ' + rnd().left(8),
      AccountId = a.Id,
      RecordTypeId = rtOutraBU,
      CloseDate = Date.today().addDays(30),
      StageName = 'Pré-Matrícula',
      // O vetor: produto da Arnone Soluções preenchido num registro que não é
      // da Arnone Soluções.
      SOL_Produto_Negocio__c = PRODUTO_RT
    );
    insert outraBU;
    Task t = new Task(
      WhatId = outraBU.Id,
      Subject = 'Tarefa de outra BU',
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today().addDays(3)
    );
    insert t;

    Test.startTest();
    update new Opportunity(
      Id = outraBU.Id,
      StageName = 'Perdido',
      STE_Motivo_Perda__c = 'Desistiu'
    );
    Test.stopTest();

    Opportunity depois = [
      SELECT StageName, RecordTypeId, SOL_Qtd_Perdas__c, SOL_Produto_Negocio__c
      FROM Opportunity
      WHERE Id = :outraBU.Id
    ];
    System.assertEquals(
      'Perdido',
      depois.StageName,
      'A outra BU perde o negócio dela normalmente.'
    );
    System.assertEquals(
      PRODUTO_RT,
      depois.SOL_Produto_Negocio__c,
      'E o produto SOL continua preenchido — o vetor está de fato armado.'
    );
    System.assertEquals(
      null,
      depois.SOL_Qtd_Perdas__c,
      'O contador de transições da Arnone Soluções NÃO foi incrementado.'
    );
    System.assertEquals(
      0,
      totalEventos(),
      'E nenhuma ocorrência da jornada SOL foi criada.'
    );
    Task tDepois = [
      SELECT Status, SOL_Cancelada_Por_Perda__c, SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE Id = :t.Id
    ];
    System.assertEquals(
      'Open',
      tDepois.Status,
      'A automação SOL não encostou na tarefa da outra BU.'
    );
    System.assertNotEquals(true, tDepois.SOL_Cancelada_Por_Perda__c);
    System.assertEquals(null, tDepois.SOL_Motivo_Cancelamento__c);
  }

  /** (5c) Contraprova: a MESMA perda, no Record Type SOL, conta. */
  @IsTest
  static void mesmaPerdaNoRecordTypeSolIncrementaERegistra() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');

    Test.startTest();
    perder(oppId);
    Test.stopTest();

    System.assertEquals(
      1,
      opp(oppId).SOL_Qtd_Perdas__c,
      'No Record Type SOL o contador anda.'
    );
    System.assertEquals(1, eventosDaOpp(oppId).size(), 'E a ocorrência nasce.');
  }

  // ======================================= 6. ATOMICIDADE NOS DOIS SENTIDOS

  /**
   * (6a) Falha ao gravar a ocorrência DESFAZ a reatribuição: proprietário,
   * contador, ciclo e tarefa nova voltam ao estado anterior. Nunca há
   * reatribuição sem evento.
   */
  @IsTest
  static void falhaAoGravarEventoDesfazAReatribuicao() {
    montarFila(3);
    Lead l = leadDistribuido(PRODUTO_RT);
    Id donoAntes = l.OwnerId;

    Test.startTest();
    // A injeção vem ANTES das tarefas: o Flow SOL_Reatribuir_Por_Falta_Contato
    // dispara na inserção da 3ª tentativa negativa, e o teste precisa alcançar
    // também esse caminho — não só a chamada explícita abaixo.
    SOLEventoJornadaService.falharGravacao = true;
    tentativasNegativas(l.Id, 3);
    SOLDistribuicaoService.ResultadoReatribuicao r = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      new List<Id>{ l.Id }
    );
    SOLEventoJornadaService.falharGravacao = false;
    Test.stopTest();

    System.assertEquals(1, r.comErro, 'A falha é reportada, não engolida.');
    System.assertEquals(0, r.reatribuidos);
    Lead depois = lead(l.Id);
    System.assertEquals(donoAntes, depois.OwnerId, 'O Lead não trocou de dono.');
    System.assertEquals(
      0,
      depois.SOL_Quantidade_Reatribuicoes__c,
      'O contador não avançou.'
    );
    System.assertEquals(0, totalEventos(), 'E nenhuma ocorrência ficou gravada.');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação'],
      'A tarefa da reatribuição também foi desfeita.'
    );
  }

  /** (6b) O mesmo no opt-out: a falha relança e o Lead não é desqualificado. */
  @IsTest
  static void falhaAoGravarEventoDesfazOOptOut() {
    montarFila(2);
    Lead l = leadDistribuido(PRODUTO_RT);

    Test.startTest();
    SOLEventoJornadaService.falharGravacao = true;
    Boolean lancou = false;
    String mensagem = null;
    try {
      SOLDistribuicaoService.registrarOptOut(new List<Id>{ l.Id });
    } catch (SOLDistribuicaoService.OptOutException e) {
      lancou = true;
      mensagem = e.getMessage();
    }
    SOLEventoJornadaService.falharGravacao = false;
    Test.stopTest();

    System.assert(lancou, 'A falha RELANÇA e aborta a transação inteira.');
    System.assertEquals(
      SOLDistribuicaoService.MSG_OPT_OUT_FALHA,
      mensagem,
      'Mensagem controlada, sem detalhe técnico.'
    );
    System.assertEquals(
      false,
      lead(l.Id).SOL_Opt_Out__c,
      'O opt-out foi desfeito junto com a ocorrência.'
    );
    System.assertEquals(0, totalEventos());
  }

  /**
   * (6c) E na perda da Oportunidade, pelo caminho de PRODUÇÃO: com o Flow
   * chamando a ação em CurrentTransaction, a falha da ocorrência aborta a
   * própria mudança para "Perdido". A Oportunidade nem chega a fechar.
   */
  @IsTest
  static void falhaAoGravarEventoDesfazAPerdaDaOportunidade() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');
    Task t = new Task(
      WhatId = oppId,
      Subject = 'Aberta',
      OwnerId = vs[0],
      Status = 'Open',
      ActivityDate = Date.today()
    );
    insert t;

    Test.startTest();
    SOLEventoJornadaService.falharGravacao = true;
    Boolean lancou = false;
    try {
      update new Opportunity(
        Id = oppId,
        StageName = 'Perdido',
        SOL_Motivo_Perda__c = 'Sem retorno'
      );
    } catch (DmlException e) {
      lancou = true;
    }
    SOLEventoJornadaService.falharGravacao = false;
    Test.stopTest();

    System.assert(lancou, 'A falha da ocorrência aborta a perda.');
    System.assertEquals(
      'Negociação',
      opp(oppId).StageName,
      'A Oportunidade não chegou a virar "Perdido".'
    );
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :t.Id].Status,
      'O cancelamento da tarefa foi desfeito com a ocorrência.'
    );
    System.assertEquals(0, totalEventos());
  }

  /**
   * (6d) O sentido inverso: falha de NEGÓCIO não deixa evento órfão. Em modo
   * somente leitura o cancelamento das tarefas quebra, e a ocorrência — que
   * seria gravada logo depois, no mesmo Savepoint — não sobra.
   */
  @IsTest
  static void falhaDeNegocioNaoDeixaEventoOrfao() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');
    insert new Task(
      WhatId = oppId,
      Subject = 'Aberta',
      OwnerId = vs[0],
      Status = 'Open',
      ActivityDate = Date.today()
    );
    // Perde de verdade (o Flow cancela a tarefa e grava a ocorrência) e depois
    // limpa o rastro: sobra uma Oportunidade JÁ em "Perdido", com tarefa aberta
    // e sem ocorrência — o cenário exato em que um evento órfão apareceria.
    update new Opportunity(
      Id = oppId,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    delete [SELECT Id FROM SOL_Evento_Jornada__c];
    Task reaberta = [SELECT Id FROM Task WHERE WhatId = :oppId LIMIT 1];
    update new Task(
      Id = reaberta.Id,
      Status = 'Open',
      SOL_Cancelada_Por_Perda__c = false,
      SOL_Motivo_Cancelamento__c = null
    );

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
        new List<Id>{ oppId },
        new Map<Id, String>{ oppId => 'Negociação' }
      );
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      lancou = true;
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'A operação de negócio falhou.');
    System.assertEquals(
      0,
      totalEventos(),
      'Operação de negócio que falhou não deixa ocorrência órfã.'
    );
    System.assertEquals(
      'Open',
      [SELECT Status FROM Task WHERE Id = :reaberta.Id].Status,
      'E nada foi gravado na tarefa.'
    );
  }

  /**
   * (6e) Perda sem a etapa anterior ABORTA. Aceitar em silêncio gravaria a
   * ocorrência sem a única informação que o relatório por etapa consome — e
   * "o Apex ignora" nunca é proteção.
   */
  @IsTest
  static void perdaSemEtapaAnteriorAbortaComMensagemPropria() {
    List<Id> vs = montarFila(2);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');
    update new Opportunity(
      Id = oppId,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    delete [SELECT Id FROM SOL_Evento_Jornada__c];
    insert new Task(
      WhatId = oppId,
      Subject = 'Reaberta',
      OwnerId = vs[0],
      Status = 'Open',
      ActivityDate = Date.today()
    );

    Test.startTest();
    String semMapa = null;
    String comPerdido = null;
    try {
      SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
        new List<Id>{ oppId },
        new Map<Id, String>()
      );
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      semMapa = e.getMessage();
    }
    try {
      SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(
        new List<Id>{ oppId },
        new Map<Id, String>{ oppId => SOLEventoJornadaService.ETAPA_PERDIDO }
      );
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      comPerdido = e.getMessage();
    }
    Test.stopTest();

    System.assertEquals(
      SOLNegocioPerdidoService.MSG_ETAPA_ANTERIOR_AUSENTE,
      semMapa,
      'Sem etapa anterior a perda é abortada com mensagem própria.'
    );
    System.assertEquals(
      SOLNegocioPerdidoService.MSG_ETAPA_ANTERIOR_AUSENTE,
      comPerdido,
      '"Perdido" é o destino, não a origem: também aborta.'
    );
    System.assertEquals(0, totalEventos(), 'Nenhuma ocorrência incompleta.');
  }

  /** (6f) Evento incompleto é recusado pelo próprio serviço de registro. */
  @IsTest
  static void eventoIncompletoERecusado() {
    Test.startTest();
    Integer recusas = 0;
    List<SOL_Evento_Jornada__c> invalidos = new List<SOL_Evento_Jornada__c>{
      new SOL_Evento_Jornada__c(),
      new SOL_Evento_Jornada__c(
        SOL_Tipo_Evento__c = SOLEventoJornadaService.TIPO_PERDA,
        SOL_Motivo__c = SOLEventoJornadaService.MOTIVO_OPT_OUT,
        SOL_Origem__c = SOLEventoJornadaService.ORIGEM_LEAD,
        SOL_Data_Ocorrencia__c = System.now(),
        SOL_Sequencia__c = 1,
        SOL_Chave_Idempotencia__c = 'OO|semRecordType',
        SOL_Lead__c = null
      )
    };
    for (SOL_Evento_Jornada__c e : invalidos) {
      try {
        SOLEventoJornadaService.registrar(new List<SOL_Evento_Jornada__c>{ e });
      } catch (SOLEventoJornadaService.EventoJornadaException ex) {
        recusas++;
      }
    }
    Integer vazios =
      SOLEventoJornadaService.registrar(null) +
      SOLEventoJornadaService.registrar(new List<SOL_Evento_Jornada__c>());
    Test.stopTest();

    System.assertEquals(2, recusas, 'Todo evento incompleto é recusado.');
    System.assertEquals(0, vazios, 'Entrada vazia é no-op, não erro.');
    System.assertEquals(0, totalEventos());
  }

  // ============================= 7. SEGURANÇA: CRUD/FLS EFETIVOS E SEM USO MANUAL

  /**
   * (7) O objeto é de BACKEND. Medimos a permissão EFETIVA por
   * `System.runAs` + `getDescribe()`, e não por um `update` de teste: DML de
   * Apex roda em modo de sistema e NÃO aplica FLS — um update que "funciona"
   * não provaria nada sobre o que o vendedor pode fazer.
   */
  @IsTest
  static void objetoEDeBackendSemCriarEditarOuExcluir() {
    User semAcesso;
    User comLeitura;
    System.runAs(contextoAtual()) {
      semAcesso = vendedor('sem' + rnd().left(3));
      comLeitura = vendedor('com' + rnd().left(3));
      insert new List<User>{ semAcesso, comLeitura };
      insert new PermissionSetAssignment(
        AssigneeId = comLeitura.Id,
        PermissionSetId = psSolComercial()
      );
    }

    Test.startTest();
    Boolean acessoSemPS;
    System.runAs(semAcesso) {
      acessoSemPS = SOL_Evento_Jornada__c.SObjectType.getDescribe()
        .isAccessible();
    }

    Boolean acessivel;
    Boolean criavel;
    Boolean editavel;
    Boolean excluivel;
    Boolean campoLegivel;
    Boolean campoEditavel;
    Boolean chaveEditavel;
    System.runAs(comLeitura) {
      Schema.DescribeSObjectResult d = SOL_Evento_Jornada__c.SObjectType.getDescribe();
      acessivel = d.isAccessible();
      criavel = d.isCreateable();
      editavel = d.isUpdateable();
      excluivel = d.isDeletable();
      Schema.DescribeFieldResult vendedorCampo = SOL_Evento_Jornada__c.SOL_Vendedor__c.getDescribe();
      campoLegivel = vendedorCampo.isAccessible();
      campoEditavel = vendedorCampo.isUpdateable();
      chaveEditavel = SOL_Evento_Jornada__c.SOL_Chave_Idempotencia__c.getDescribe()
        .isUpdateable();
    }
    Test.stopTest();

    System.assertEquals(
      false,
      acessoSemPS,
      'Sem PS_SOL_Comercial o objeto é invisível: OWD Private + CRUD fechado.'
    );
    System.assertEquals(true, acessivel, 'Com o PS, leitura para relatório.');
    System.assertEquals(false, criavel, 'Nenhum Permission Set concede Create.');
    System.assertEquals(false, editavel, 'Nem Edit.');
    System.assertEquals(false, excluivel, 'Nem Delete.');
    System.assertEquals(true, campoLegivel, 'O campo do relatório é legível.');
    System.assertEquals(false, campoEditavel, 'E somente leitura.');
    System.assertEquals(
      false,
      chaveEditavel,
      'A chave de idempotência nunca é editável por operador.'
    );
  }

  /**
   * (7b) OWD Private de verdade: o vendedor com o Permission Set enxerga a
   * ocorrência da qual é PROPRIETÁRIO e não enxerga a de outro vendedor. É esse
   * modelo — e não "View All" — que dá o consolidado ao gestor pela hierarquia.
   */
  @IsTest
  static void owdPrivadaSeparaAsOcorrenciasPorVendedor() {
    List<Id> vs = montarFila(3);
    Lead l = leadDistribuido(PRODUTO_RT);
    Id dono = l.OwnerId;
    tentativasNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });

    // Os dois já têm PS_SOL_Comercial (montarFila): o que separa a visão é a
    // OWD Private mais o proprietário do evento, não o Permission Set.
    Id outroVendedor = null;
    for (Id v : vs) {
      if (v != dono && v != lead(l.Id).OwnerId) {
        outroVendedor = v;
        break;
      }
    }

    Test.startTest();
    Integer visiveisParaODono;
    System.runAs(new User(Id = dono)) {
      visiveisParaODono = [SELECT COUNT() FROM SOL_Evento_Jornada__c];
    }
    Integer visiveisParaOOutro;
    System.runAs(new User(Id = outroVendedor)) {
      visiveisParaOOutro = [SELECT COUNT() FROM SOL_Evento_Jornada__c];
    }
    Test.stopTest();

    System.assertEquals(
      1,
      visiveisParaODono,
      'O vendedor do instante da ocorrência é o proprietário e a enxerga.'
    );
    System.assertEquals(
      0,
      visiveisParaOOutro,
      'Outro vendedor, sem hierarquia acima, não enxerga.'
    );
  }

  // ============ 8. INSUMO DO RELATÓRIO: CONTAGEM, PERÍODO E PERCENTUAL

  /**
   * (8a) O que o relatório soma, conferido contra SOQL independente: os quatro
   * motivos, a quantidade por motivo e o percentual do total fechando em 100%.
   *
   * A confrontação usa uma consulta agregada que NÃO reaproveita nada do
   * caminho de gravação — é a checagem cruzada que o card pede.
   */
  @IsTest
  static void contagemPorMotivoEPercentualConferemComSoql() {
    List<Id> vs = montarFila(3);

    // Motivo 1 — reatribuição por falta de contato (2 ocorrências).
    Lead l1 = leadDistribuido(PRODUTO_RT);
    tentativasNegativas(l1.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l1.Id });
    abrirCicloUmMinutoAtras(l1.Id);
    tentativasNegativas(l1.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l1.Id });

    // Motivo 2 — reatribuição por estouro do prazo total (1).
    Id oppPrazo = oppVencida(PRODUTO_ART, vs[0]);
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppPrazo });

    // Motivo 3 — Lead perdido por opt-out (1).
    Lead l2 = leadDistribuido(PRODUTO_ART);
    SOLDistribuicaoService.registrarOptOut(new List<Id>{ l2.Id });

    // Motivo 4 — Oportunidade perdida (1), pela transição real.
    Id oppPerda = novaOpp(PRODUTO_RT, true, vs[0], null, null, 'Negociação');

    Test.startTest();
    update new Opportunity(
      Id = oppPerda,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno'
    );
    Test.stopTest();

    Map<String, Integer> porMotivo = new Map<String, Integer>();
    Integer total = 0;
    for (AggregateResult ar : [
      SELECT SOL_Motivo__c motivo, COUNT(Id) qtd
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Record_Type_Origem__c = 'SOL'
      GROUP BY SOL_Motivo__c
    ]) {
      Integer q = (Integer) ar.get('qtd');
      porMotivo.put((String) ar.get('motivo'), q);
      total += q;
    }

    System.assertEquals(4, porMotivo.size(), 'Os quatro motivos aparecem.');
    System.assertEquals(
      2,
      porMotivo.get(SOLEventoJornadaService.MOTIVO_FALTA_CONTATO)
    );
    System.assertEquals(
      1,
      porMotivo.get(SOLEventoJornadaService.MOTIVO_PRAZO_TOTAL)
    );
    System.assertEquals(1, porMotivo.get(SOLEventoJornadaService.MOTIVO_OPT_OUT));
    System.assertEquals(
      1,
      porMotivo.get(SOLEventoJornadaService.MOTIVO_OPORTUNIDADE_PERDIDA)
    );
    System.assertEquals(5, total, 'Total independente das somas por motivo.');
    System.assertEquals(
      total,
      totalEventos(),
      'A soma dos motivos é o total geral — o mesmo que RowCount no relatório.'
    );

    // "% do total" do relatório é RowCount/PARENTGROUPVAL(RowCount,
    // GRAND_SUMMARY). Reproduzido aqui, tem de fechar em 100%.
    Decimal somaPercentual = 0;
    for (Integer q : porMotivo.values()) {
      somaPercentual += (Decimal.valueOf(q) / total) * 100;
    }
    System.assertEquals(
      100,
      somaPercentual.setScale(2),
      'Os percentuais somam 100%, salvo arredondamento.'
    );

    // Contagem por Owner, que é como o gestor lê o relatório por vendedor.
    Integer comVendedor = [
      SELECT COUNT()
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Vendedor__c != NULL
    ];
    System.assertEquals(
      total,
      comVendedor,
      'Toda ocorrência sabe de quem era o negócio.'
    );
  }

  /**
   * (8b) O filtro de período do relatório recorta por DATA DA OCORRÊNCIA. Um
   * evento antigo e um de hoje comprovam que o eixo é esse campo — e não o
   * CreatedDate, que aqui é o mesmo para os dois.
   */
  @IsTest
  static void filtroDePeriodoRecortaPelaDataDaOcorrencia() {
    montarFila(2);
    Lead l = leadDistribuido(PRODUTO_RT);
    Datetime hoje = System.now();
    Datetime anoPassado = hoje.addDays(-400);

    Test.startTest();
    SOLEventoJornadaService.registrar(
      new List<SOL_Evento_Jornada__c>{
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          1,
          anoPassado
        ),
        SOLEventoJornadaService.reatribuicaoPorFaltaDeContato(
          l,
          l.OwnerId,
          UserInfo.getUserId(),
          2,
          hoje
        )
      }
    );
    Test.stopTest();

    Datetime corte = hoje.addDays(-30);
    Integer noPeriodo = [
      SELECT COUNT()
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Data_Ocorrencia__c >= :corte
    ];
    Integer foraDoPeriodo = [
      SELECT COUNT()
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Data_Ocorrencia__c < :corte
    ];
    Integer criadosHoje = [
      SELECT COUNT()
      FROM SOL_Evento_Jornada__c
      WHERE CreatedDate = TODAY
    ];

    System.assertEquals(1, noPeriodo, 'Só a ocorrência do período entra.');
    System.assertEquals(1, foraDoPeriodo, 'A antiga fica de fora.');
    System.assertEquals(
      2,
      criadosHoje,
      'Ambas foram CRIADAS hoje: filtrar por CreatedDate daria o número errado.'
    );
  }
}
