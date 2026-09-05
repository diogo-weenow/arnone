/**
 * CLICKUP-9434 — Testes da criação da tarefa diária de ligação da cadência de
 * contato da Arnone Soluções.
 *
 * Cobrem: o dia 1 na distribuição inicial e na reatribuição; a criação dos dias
 * 2 e 3 com o vencimento que o motor informa; idempotência por Lead + ciclo +
 * dia (inclusive contra tarefa já concluída/cancelada e contra duplicata dentro
 * do mesmo lote); bulk sem escalar consultas; Lead de outra BU, convertido,
 * perdido, com contato efetivado ou opt-out; e a obrigatoriedade do resultado
 * para concluir — agora também nos dias 2 e 3, que não têm prazo em minutos.
 *
 * O Flow SOL_Distribuir_Lead está ATIVO: inserir um Lead SOL dispara a
 * distribuição real e, com ela, a ligação do dia 1. Os testes usam isso de
 * propósito — é o caminho de produção — apontando a distribuição para uma fila
 * SINTÉTICA (mesma costura de `SOLDistribuicaoServiceTest`), sem desativar
 * automação nenhuma. Nenhum teste depende de permission set: os serviços rodam
 * em contexto de sistema.
 */
@IsTest
private class SOLCadenciaContatoTest {
  private static final String FILA_SINTETICA = 'RR_Cad_SOL_9434';
  private static final String CNPJ = '11222333000181';

  private static final String CANAL_LIGACAO = 'Ligação';
  private static final String TIPO_CONTATO = 'Contato';
  private static final String STATUS_ABERTO = 'Open';
  private static final String STATUS_CONCLUIDO = 'Completed';

  private static final String RES_ATENDEU = 'Atendeu';
  private static final String RES_NAO_ATENDEU = 'Não atendeu';
  private static final String RES_NAO_FOI_POSSIVEL = 'Não foi possível ligar';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ============================================================ helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User montarUsuario(String apelido) {
    String unico =
      String.valueOf(Math.abs(Crypto.getRandomInteger())) + apelido;
    return new User(
      FirstName = 'Cad',
      LastName = 'Teste ' + apelido,
      Alias = ('cd' + apelido).left(8),
      Email = 'cad.' + apelido + '@arnone.invalid',
      Username = 'cad.svc.' + unico + '@arnone.clickup9434.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private class Cenario {
    Id filaId;
    List<Id> vendedores = new List<Id>();
  }

  /**
   * Fila sintética com `qtdVendedores` membros diretos e ativos, e a
   * distribuição apontada para ela. Chamar ANTES de inserir Leads SOL.
   */
  private static Cenario montarCenario(Integer qtdVendedores) {
    Cenario c = new Cenario();
    List<User> criados = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      criados.add(montarUsuario('v' + i));
    }
    System.runAs(contextoAtual()) {
      insert criados;
      Group fila = new Group(
        Name = 'Cad Svc SOL 9434',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      c.filaId = fila.Id;
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : criados) {
        gms.add(new GroupMember(GroupId = c.filaId, UserOrGroupId = u.Id));
      }
      insert gms;
    }
    for (User u : criados) {
      c.vendedores.add(u.Id);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    return c;
  }

  private static Id rtLead(String devName) {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(devName)
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
   * Insere `qtd` Leads SOL — o Flow ativo distribui e cria a ligação do dia 1 —
   * e devolve os Leads já com dono e ciclo de contato abertos.
   */
  private static List<Lead> leadsDistribuidos(Integer qtd) {
    Id rt = rtLead('SOL');
    String st = statusLead();
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < qtd; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rt,
          LastName = 'Lead SOL ' + i,
          Company = 'Empresa ' + i,
          Status = st,
          CNPJ__c = CNPJ
        )
      );
    }
    insert leads;

    List<Lead> distribuidos = [
      SELECT Id, OwnerId, SOL_Data_Inicio_Ciclo_Contato__c
      FROM Lead
      WHERE Id IN :leads
      ORDER BY CreatedDate ASC, Id ASC
    ];
    for (Lead l : distribuidos) {
      System.assertNotEquals(
        null,
        l.SOL_Data_Inicio_Ciclo_Contato__c,
        'Pré-condição: o Lead precisa sair da distribuição com ciclo aberto.'
      );
    }
    return distribuidos;
  }

  private static Lead recarregar(Id leadId) {
    return [
      SELECT Id, OwnerId, SOL_Data_Inicio_Ciclo_Contato__c, IsConverted
      FROM Lead
      WHERE Id = :leadId
    ];
  }

  /** Tarefas de LIGAÇÃO da cadência ligadas a este Lead, por dia. */
  private static List<Task> ligacoesDe(Id leadId) {
    return [
      SELECT
        Id,
        Subject,
        WhoId,
        OwnerId,
        Status,
        ActivityDate,
        SOL_Prazo_Contato__c,
        SOL_Tipo_Tarefa__c,
        SOL_Resultado_Contato__c,
        SOL_Canal_Contato__c,
        SOL_Dia_Cadencia__c,
        SOL_Ciclo_Contato__c
      FROM Task
      WHERE WhoId = :leadId AND SOL_Canal_Contato__c = :CANAL_LIGACAO
      ORDER BY SOL_Dia_Cadencia__c ASC, CreatedDate ASC
    ];
  }

  private static List<Task> ligacoesDoDia(Id leadId, Integer dia) {
    List<Task> filtradas = new List<Task>();
    for (Task t : ligacoesDe(leadId)) {
      if (
        t.SOL_Dia_Cadencia__c != null &&
        t.SOL_Dia_Cadencia__c.intValue() == dia
      ) {
        filtradas.add(t);
      }
    }
    return filtradas;
  }

  private static SOLCadenciaContatoService.Solicitacao pedido(
    Id leadId,
    Integer dia,
    Date vencimento
  ) {
    return new SOLCadenciaContatoService.Solicitacao(leadId, dia, vencimento);
  }

  private static SOLCadenciaContatoService.Resultado criar(
    List<SOLCadenciaContatoService.Solicitacao> pedidos
  ) {
    return SOLCadenciaContatoService.criarLigacoes(pedidos);
  }

  // ==================================================== dia 1: distribuição

  @IsTest
  static void distribuicaoInicialCriaLigacaoDoDia1Classificada() {
    Cenario c = montarCenario(1);

    Test.startTest();
    Lead l = leadsDistribuidos(1)[0];
    Test.stopTest();

    List<Task> ligacoes = ligacoesDe(l.Id);
    System.assertEquals(
      1,
      ligacoes.size(),
      'A distribuição cria exatamente uma ligação.'
    );

    Task t = ligacoes[0];
    System.assertEquals(l.Id, t.WhoId, 'A tarefa é vinculada ao Lead.');
    System.assertEquals(
      l.OwnerId,
      t.OwnerId,
      'A tarefa é do proprietário vigente do Lead no ciclo.'
    );
    System.assertEquals(
      c.vendedores[0],
      t.OwnerId,
      'Dono = o vendedor da fila.'
    );
    System.assertEquals(STATUS_ABERTO, t.Status, 'Nasce aberta.');
    System.assertEquals(
      TIPO_CONTATO,
      t.SOL_Tipo_Tarefa__c,
      'Continua sendo tarefa de contato (compatibilidade CLICKUP-9417).'
    );
    System.assertEquals(
      CANAL_LIGACAO,
      t.SOL_Canal_Contato__c,
      'Identificável como canal Ligação.'
    );
    System.assertEquals(
      1,
      t.SOL_Dia_Cadencia__c.intValue(),
      'É o dia 1 da cadência.'
    );
    System.assertEquals(
      l.SOL_Data_Inicio_Ciclo_Contato__c,
      t.SOL_Ciclo_Contato__c,
      'Carrega o ciclo do vendedor.'
    );
    System.assertNotEquals(
      null,
      t.SOL_Prazo_Contato__c,
      'Dia 1 mantém o prazo de 5 minutos úteis.'
    );
    System.assertEquals(
      null,
      t.SOL_Resultado_Contato__c,
      'O resultado é do vendedor, não da automação.'
    );
  }

  @IsTest
  static void classificacaoNaoDependeDoSubject() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];

    // O Subject é editável pelo vendedor: mexer nele não pode desclassificar a
    // tarefa nem abrir espaço para uma segunda ligação do mesmo dia.
    Task t = ligacoesDe(l.Id)[0];
    t.Subject = 'Ligar depois do almoço';
    update t;

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 1, null) }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      r.criadas,
      'O Subject alterado não libera duplicata.'
    );
    System.assertEquals(1, r.jaExistentes, 'O dia 1 continua ocupado.');
    System.assertEquals(1, ligacoesDoDia(l.Id, 1).size(), 'Segue uma única.');
  }

  @IsTest
  static void reatribuicaoCriaLigacaoDoDia1NoNovoCiclo() {
    Cenario c = montarCenario(2);
    Lead l = leadsDistribuidos(1)[0];
    Id donoOriginal = l.OwnerId;
    Datetime cicloOriginal = l.SOL_Data_Inicio_Ciclo_Contato__c;

    // 3 tentativas sem contato no ciclo do vendedor atual disparam a troca.
    List<Task> tentativas = new List<Task>();
    for (Integer i = 0; i < 3; i++) {
      tentativas.add(
        new Task(
          Subject = 'Tentativa ' + i,
          WhoId = l.Id,
          OwnerId = donoOriginal,
          Status = STATUS_CONCLUIDO,
          SOL_Tipo_Tarefa__c = TIPO_CONTATO,
          SOL_Resultado_Contato__c = RES_NAO_ATENDEU
        )
      );
    }
    insert tentativas;

    Test.startTest();
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead depois = recarregar(l.Id);
    System.assertNotEquals(
      donoOriginal,
      depois.OwnerId,
      'Pré-condição: a reatribuição precisa ter trocado o vendedor.'
    );
    System.assert(
      c.vendedores.contains(depois.OwnerId),
      'O novo dono sai da mesma fila.'
    );

    List<Task> dia1 = ligacoesDoDia(l.Id, 1);
    System.assertEquals(
      2,
      dia1.size(),
      'Cada ciclo tem o seu dia 1: o do vendedor anterior e o do novo.'
    );

    Set<Datetime> ciclos = new Set<Datetime>();
    Task doNovoCiclo = null;
    for (Task t : dia1) {
      ciclos.add(t.SOL_Ciclo_Contato__c);
      if (t.SOL_Ciclo_Contato__c != cicloOriginal) {
        doNovoCiclo = t;
      }
    }
    System.assertEquals(2, ciclos.size(), 'Os ciclos são distintos.');
    System.assertNotEquals(
      null,
      doNovoCiclo,
      'A ligação do novo ciclo existe.'
    );
    System.assertEquals(
      depois.OwnerId,
      doNovoCiclo.OwnerId,
      'A nova ligação é do novo proprietário.'
    );
    System.assertEquals(
      depois.SOL_Data_Inicio_Ciclo_Contato__c,
      doNovoCiclo.SOL_Ciclo_Contato__c,
      'E carrega o ciclo reiniciado.'
    );
    System.assertNotEquals(
      null,
      doNovoCiclo.SOL_Prazo_Contato__c,
      'A reatribuição mantém os 5 minutos úteis do dia 1.'
    );
  }

  // ==================================================== dias 2 e 3: motor

  @IsTest
  static void motorCriaDias2E3ComOVencimentoInformado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date d2 = Date.today().addDays(1);
    Date d3 = Date.today().addDays(2);

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, d2),
        pedido(l.Id, 3, d3)
      }
    );
    Test.stopTest();

    System.assertEquals(2, r.criadas, 'Duas ligações criadas.');
    System.assertEquals(0, r.ignoradas, 'Nenhum pedido ignorado.');
    System.assertEquals(0, r.comErro, 'Sem falha.');

    Task t2 = ligacoesDoDia(l.Id, 2)[0];
    Task t3 = ligacoesDoDia(l.Id, 3)[0];

    System.assertEquals(
      d2,
      t2.ActivityDate,
      'Dia 2 vence no dia útil informado.'
    );
    System.assertEquals(
      d3,
      t3.ActivityDate,
      'Dia 3 vence no dia útil informado.'
    );
    for (Task t : new List<Task>{ t2, t3 }) {
      System.assertEquals(l.Id, t.WhoId, 'Vinculada ao Lead.');
      System.assertEquals(l.OwnerId, t.OwnerId, 'Do proprietário do ciclo.');
      System.assertEquals(STATUS_ABERTO, t.Status, 'Nasce aberta.');
      System.assertEquals(
        TIPO_CONTATO,
        t.SOL_Tipo_Tarefa__c,
        'Tarefa de contato.'
      );
      System.assertEquals(
        CANAL_LIGACAO,
        t.SOL_Canal_Contato__c,
        'Canal Ligação.'
      );
      System.assertEquals(
        l.SOL_Data_Inicio_Ciclo_Contato__c,
        t.SOL_Ciclo_Contato__c,
        'Mesmo ciclo do dia 1.'
      );
      System.assertEquals(
        null,
        t.SOL_Prazo_Contato__c,
        'Dias 2 e 3 vencem no dia, não em minutos úteis.'
      );
    }
  }

  @IsTest
  static void dia2SemVencimentoEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, null) }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      r.criadas,
      'Sem dia útil não há vencimento a gravar.'
    );
    System.assertEquals(1, r.ignoradas, 'Pedido incompleto é ignorado.');
    System.assertEquals(0, ligacoesDoDia(l.Id, 2).size(), 'Nada foi criado.');
  }

  @IsTest
  static void pedidosMalFormadosSaoIgnoradosSemTocarNoBanco() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        null,
        pedido(null, 2, Date.today()),
        pedido(l.Id, null, Date.today()),
        pedido(l.Id, 0, Date.today()),
        pedido(l.Id, 4, Date.today()),
        pedido(UserInfo.getUserId(), 2, Date.today())
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Nada criado.');
    System.assertEquals(
      6,
      r.ignoradas,
      'Todos os pedidos inválidos ignorados.'
    );
    System.assertEquals(
      1,
      ligacoesDe(l.Id).size(),
      'Só o dia 1 da distribuição.'
    );
  }

  @IsTest
  static void listaNulaOuVaziaDevolveResultadoZerado() {
    Test.startTest();
    SOLCadenciaContatoService.Resultado nulo = criar(null);
    SOLCadenciaContatoService.Resultado vazio = criar(
      new List<SOLCadenciaContatoService.Solicitacao>()
    );
    Test.stopTest();

    System.assertEquals(0, nulo.criadas, 'Nulo: nada criado.');
    System.assertEquals(0, nulo.ignoradas, 'Nulo: nada a ignorar.');
    System.assertEquals(0, vazio.criadas, 'Vazio: nada criado.');
    System.assertEquals(0, vazio.comErro, 'Vazio: sem erro.');
  }

  // ==================================================== idempotência

  @IsTest
  static void reprocessarOMesmoDiaNaoDuplica() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date d2 = Date.today().addDays(1);

    Test.startTest();
    SOLCadenciaContatoService.Resultado primeira = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, d2) }
    );
    SOLCadenciaContatoService.Resultado segunda = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, d2) }
    );
    Test.stopTest();

    System.assertEquals(1, primeira.criadas, 'A primeira cria.');
    System.assertEquals(0, segunda.criadas, 'A segunda não cria.');
    System.assertEquals(
      1,
      segunda.jaExistentes,
      'E reporta como já existente.'
    );
    System.assertEquals(1, ligacoesDoDia(l.Id, 2).size(), 'Uma única tarefa.');
  }

  @IsTest
  static void duplicataDentroDoMesmoLoteNaoDuplica() {
    // Proteção equivalente à concorrência DENTRO da transação: dois pedidos
    // idênticos no mesmo lote não podem virar duas Tasks. Entre transações
    // quem serializa é o FOR UPDATE do Lead, tomado antes da leitura.
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date d2 = Date.today().addDays(1);

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, d2),
        pedido(l.Id, 2, d2),
        pedido(l.Id, 2, Date.today().addDays(9))
      }
    );
    Test.stopTest();

    System.assertEquals(1, r.criadas, 'Uma só ligação para o dia 2.');
    System.assertEquals(2, r.jaExistentes, 'As repetições são absorvidas.');
    System.assertEquals(1, ligacoesDoDia(l.Id, 2).size(), 'Sem duplicata.');
  }

  @IsTest
  static void tarefaJaConcluidaContinuaOcupandoODia() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date d2 = Date.today().addDays(1);

    criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, d2) }
    );
    Task t = ligacoesDoDia(l.Id, 2)[0];
    t.SOL_Resultado_Contato__c = RES_NAO_ATENDEU;
    t.Status = STATUS_CONCLUIDO;
    update t;

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, d2) }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      r.criadas,
      'Ligação já feita não é recriada no reprocessamento.'
    );
    System.assertEquals(1, r.jaExistentes, 'O dia continua ocupado.');
    System.assertEquals(1, ligacoesDoDia(l.Id, 2).size(), 'Uma única tarefa.');
  }

  @IsTest
  static void tarefaVencidaPermaneceAbertaENaoEhReprogramada() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date ontem = Date.today().addDays(-3);

    criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, ontem) }
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(5))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Não cria uma segunda para o mesmo dia.');
    List<Task> dia2 = ligacoesDoDia(l.Id, 2);
    System.assertEquals(1, dia2.size(), 'Continua uma só.');
    System.assertEquals(
      ontem,
      dia2[0].ActivityDate,
      'A tarefa vencida NÃO é reprogramada.'
    );
    System.assertEquals(
      STATUS_ABERTO,
      dia2[0].Status,
      'E permanece aberta e vencida.'
    );
  }

  // ==================================================== bulk

  @IsTest
  static void loteComMultiplosLeadsNaoEscalaConsultas() {
    montarCenario(2);
    List<Lead> leads = leadsDistribuidos(5);
    Date d2 = Date.today().addDays(1);

    // Aquece o cache do calendário para comparar deltas comparáveis.
    SOLBusinessHoursHelper.businessHoursId();

    List<SOLCadenciaContatoService.Solicitacao> umSo = new List<SOLCadenciaContatoService.Solicitacao>{
      pedido(leads[0].Id, 2, d2)
    };
    List<SOLCadenciaContatoService.Solicitacao> lote = new List<SOLCadenciaContatoService.Solicitacao>();
    for (Integer i = 1; i < leads.size(); i++) {
      lote.add(pedido(leads[i].Id, 2, d2));
      lote.add(pedido(leads[i].Id, 3, Date.today().addDays(2)));
    }

    Test.startTest();
    Integer antesUm = Limits.getQueries();
    SOLCadenciaContatoService.Resultado rUm = criar(umSo);
    Integer deltaUm = Limits.getQueries() - antesUm;

    Integer antesLote = Limits.getQueries();
    SOLCadenciaContatoService.Resultado rLote = criar(lote);
    Integer deltaLote = Limits.getQueries() - antesLote;
    Test.stopTest();

    System.assertEquals(1, rUm.criadas, 'Um Lead, uma ligação.');
    System.assertEquals(8, rLote.criadas, '4 Leads × 2 dias.');
    System.assertEquals(
      deltaUm,
      deltaLote,
      'As consultas não escalam com o tamanho do lote (nada de SOQL em laço).'
    );
    System.assert(
      deltaLote <= 3,
      'O lote inteiro cabe em poucas consultas; usou ' + deltaLote
    );

    for (Integer i = 1; i < leads.size(); i++) {
      System.assertEquals(
        2,
        ligacoesDoDia(leads[i].Id, 2).size() +
        ligacoesDoDia(leads[i].Id, 3).size(),
        'Cada Lead do lote recebeu os dois dias.'
      );
    }
  }

  // ==================================================== fora do escopo

  @IsTest
  static void leadDeOutraBUEhIgnorado() {
    montarCenario(1);

    // Sem o Record Type SOL. O ciclo é preenchido à mão justamente para que a
    // ÚNICA razão possível da recusa seja a BU.
    Lead outro = new Lead(
      LastName = 'Lead de outra BU',
      Company = 'Outra Empresa',
      Status = statusLead(),
      SOL_Data_Inicio_Ciclo_Contato__c = System.now()
    );
    insert outro;
    System.assertNotEquals(
      rtLead('SOL'),
      [SELECT RecordTypeId FROM Lead WHERE Id = :outro.Id].RecordTypeId,
      'Pré-condição: este Lead precisa estar FORA da Arnone Soluções.'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(outro.Id, 2, Date.today().addDays(1))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Lead de outra BU não recebe ligação.');
    System.assertEquals(1, r.ignoradas, 'É ignorado, sem erro.');
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :outro.Id],
      'Nenhum efeito colateral no Lead de outra BU.'
    );
  }

  @IsTest
  static void leadSemCicloAbertoEhIgnorado() {
    montarCenario(1);
    // Lead SOL sem ciclo aberto: o mesmo estado de um Lead ainda não
    // distribuído ou estacionado em fallback na fila.
    Lead semCiclo = leadsDistribuidos(1)[0];
    update new Lead(Id = semCiclo.Id, SOL_Data_Inicio_Ciclo_Contato__c = null);

    Lead recarregado = recarregar(semCiclo.Id);
    System.assertEquals(
      null,
      recarregado.SOL_Data_Inicio_Ciclo_Contato__c,
      'Pré-condição: sem ciclo aberto.'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(semCiclo.Id, 2, Date.today().addDays(1))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Sem ciclo não há cadência.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
  }

  @IsTest
  static void leadInexistenteEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Id idRemovido = l.Id;
    delete l;

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(idRemovido, 2, Date.today().addDays(1))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Lead inexistente não gera tarefa.');
    System.assertEquals(1, r.ignoradas, 'Ignorado, sem erro.');
  }

  @IsTest
  static void leadConvertidoEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];

    l.SOL_Status_Procuracao__c = 'Recebida';
    update l;

    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1]
      .MasterLabel
    );
    Database.LeadConvertResult lcr = Database.convertLead(lc);
    System.assert(lcr.isSuccess(), 'Pré-condição: o Lead precisa converter.');

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(1))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Lead convertido não recebe ligação.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
    System.assertEquals(0, ligacoesDoDia(l.Id, 2).size(), 'Nada criado.');
  }

  @IsTest
  static void leadComContatoEfetivadoEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    update new Lead(Id = l.Id, SOL_Contato_Efetivado__c = true);

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(1))
      }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      r.criadas,
      'Contato efetivado encerra a cadência: nada de ligação nova.'
    );
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
  }

  @IsTest
  static void leadComOptOutEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    // Opt-out e motivo andam juntos (VR SOL_Desqualificacao_Coerente).
    update new Lead(
      Id = l.Id,
      SOL_Opt_Out__c = true,
      SOL_Motivo_Desqualificacao__c = 'Opt-out'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(1))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Opt-out encerra a cadência.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
  }

  @IsTest
  static void leadComNegocioPerdidoEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    update new Lead(
      Id = l.Id,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = 'Negócio perdido'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(1))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Negócio perdido encerra a cadência.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
    System.assertEquals(0, ligacoesDoDia(l.Id, 2).size(), 'Nada criado.');
  }

  // ==================================================== API de montagem

  @IsTest
  static void montarPrimeirasLigacoesIgnoraEntradasInvalidas() {
    Cenario c = montarCenario(1);
    Lead valido = leadsDistribuidos(1)[0];

    List<Lead> entradas = new List<Lead>{
      null,
      // sem Id
      new Lead(
        OwnerId = c.vendedores[0],
        SOL_Data_Inicio_Ciclo_Contato__c = System.now()
      ),
      // sem ciclo
      new Lead(Id = valido.Id, OwnerId = c.vendedores[0]),
      // dono é uma FILA (Group) — Task.OwnerId não aceita
      new Lead(
        Id = valido.Id,
        OwnerId = c.filaId,
        SOL_Data_Inicio_Ciclo_Contato__c = System.now()
      )
    };

    Test.startTest();
    List<Task> nenhuma = SOLCadenciaContatoService.montarPrimeirasLigacoes(
      entradas,
      System.now()
    );
    List<Task> vazio = SOLCadenciaContatoService.montarPrimeirasLigacoes(
      null,
      System.now()
    );
    List<Task> semInstante = SOLCadenciaContatoService.montarPrimeirasLigacoes(
      new List<Lead>{ valido },
      null
    );
    List<Task> uma = SOLCadenciaContatoService.montarPrimeirasLigacoes(
      new List<Lead>{ valido },
      System.now()
    );
    Test.stopTest();

    System.assertEquals(0, nenhuma.size(), 'Entradas inválidas são ignoradas.');
    System.assertEquals(0, vazio.size(), 'Lista nula devolve vazio.');
    System.assertEquals(0, semInstante.size(), 'Sem instante não há prazo.');
    System.assertEquals(1, uma.size(), 'A entrada válida vira uma tarefa.');
    System.assertEquals(1, uma[0].SOL_Dia_Cadencia__c.intValue(), 'É o dia 1.');
    System.assertEquals(
      CANAL_LIGACAO,
      uma[0].SOL_Canal_Contato__c,
      'Canal Ligação.'
    );
  }

  @IsTest
  static void dia1UsaCincoMinutosUteisDoCalendario() {
    montarCenario(1);
    Lead valido = leadsDistribuidos(1)[0];
    Id bhId = SOLBusinessHoursHelper.businessHoursId();
    System.assertNotEquals(
      null,
      bhId,
      'Business Hours "Arnone Soluções - Horário Comercial" é pré-requisito.'
    );
    Datetime origem = Datetime.newInstanceGmt(2026, 9, 8, 13, 0, 0);

    Test.startTest();
    List<Task> tarefas = SOLCadenciaContatoService.montarPrimeirasLigacoes(
      new List<Lead>{ valido },
      origem
    );
    Test.stopTest();

    System.assertEquals(
      BusinessHours.add(bhId, origem, 5L * 60L * 1000L),
      tarefas[0].SOL_Prazo_Contato__c,
      'O prazo do dia 1 são 5 minutos ÚTEIS — sem cálculo manual de calendário.'
    );
  }

  @IsTest
  static void semCalendarioMantemOsCincoMinutosCorridos() {
    montarCenario(1);
    Lead valido = leadsDistribuidos(1)[0];
    // Fallback herdado do CLICKUP-9396: org sem o Business Hours implantado
    // não pode travar a distribuição.
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    Datetime origem = Datetime.newInstanceGmt(2026, 9, 8, 13, 0, 0);

    Test.startTest();
    List<Task> tarefas = SOLCadenciaContatoService.montarPrimeirasLigacoes(
      new List<Lead>{ valido },
      origem
    );
    Test.stopTest();

    System.assertEquals(
      origem.addMinutes(5),
      tarefas[0].SOL_Prazo_Contato__c,
      'Sem calendário, 5 minutos corridos — exatamente como antes.'
    );
  }

  // ==================================================== conclusão da tarefa

  @IsTest
  static void dia1NaoConcluiSemResultado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Task t = ligacoesDoDia(l.Id, 1)[0];

    Test.startTest();
    String erro = '';
    try {
      t.Status = STATUS_CONCLUIDO;
      update t;
    } catch (DmlException e) {
      erro = e.getMessage();
    }
    Test.stopTest();

    System.assert(
      erro.contains('Informe o resultado da ligação'),
      'A conclusão sem resultado continua bloqueada. Recebido: ' + erro
    );
  }

  @IsTest
  static void dias2E3TambemNaoConcluemSemResultado() {
    // Regressão do CLICKUP-9434: os dias 2 e 3 não têm SOL_Prazo_Contato__c,
    // então dependem do classificador estruturado na VR.
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(1)),
        pedido(l.Id, 3, Date.today().addDays(2))
      }
    );

    Test.startTest();
    List<String> erros = new List<String>();
    for (Integer dia : new List<Integer>{ 2, 3 }) {
      Task t = ligacoesDoDia(l.Id, dia)[0];
      System.assertEquals(
        null,
        t.SOL_Prazo_Contato__c,
        'Pré-condição: o dia ' + dia + ' não tem prazo em minutos.'
      );
      try {
        t.Status = STATUS_CONCLUIDO;
        update t;
        erros.add('');
      } catch (DmlException e) {
        erros.add(e.getMessage());
      }
    }
    Test.stopTest();

    for (Integer i = 0; i < erros.size(); i++) {
      System.assert(
        erros[i].contains('Informe o resultado da ligação'),
        'O dia ' +
          (i + 2) +
          ' também exige resultado para concluir. Recebido: ' +
          erros[i]
      );
    }
  }

  @IsTest
  static void concluiComCadaResultadoPermitido() {
    montarCenario(2);
    List<Lead> leads = leadsDistribuidos(3);
    List<String> resultados = new List<String>{
      RES_NAO_ATENDEU,
      RES_NAO_FOI_POSSIVEL,
      RES_ATENDEU
    };

    Test.startTest();
    for (Integer i = 0; i < leads.size(); i++) {
      Task t = ligacoesDoDia(leads[i].Id, 1)[0];
      t.SOL_Resultado_Contato__c = resultados[i];
      t.Status = STATUS_CONCLUIDO;
      update t;
    }
    Test.stopTest();

    for (Integer i = 0; i < leads.size(); i++) {
      Task t = ligacoesDoDia(leads[i].Id, 1)[0];
      System.assertEquals(
        resultados[i],
        t.SOL_Resultado_Contato__c,
        'O resultado "' + resultados[i] + '" continua disponível.'
      );
      System.assertEquals(
        STATUS_CONCLUIDO,
        t.Status,
        'A tarefa conclui normalmente com resultado preenchido.'
      );
      System.assertEquals(
        CANAL_LIGACAO,
        t.SOL_Canal_Contato__c,
        'A classificação sobrevive à conclusão.'
      );
    }
  }

  @IsTest
  static void contatoEfetivadoContinuaCancelandoAsLigacoesPendentes() {
    // Compatibilidade com o CLICKUP-9417: as ligações dos dias 2 e 3, por
    // serem SOL_Tipo_Tarefa__c = "Contato", continuam sendo canceladas quando
    // o contato é efetivado. Nada nesta entrega mexe naquela regra.
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(1)),
        pedido(l.Id, 3, Date.today().addDays(2))
      }
    );
    System.assertEquals(
      3,
      ligacoesDe(l.Id).size(),
      'Pré-condição: 3 ligações.'
    );

    Test.startTest();
    Task dia1 = ligacoesDoDia(l.Id, 1)[0];
    dia1.SOL_Resultado_Contato__c = RES_ATENDEU;
    dia1.Status = STATUS_CONCLUIDO;
    update dia1;
    Test.stopTest();

    Integer abertas = 0;
    for (Task t : ligacoesDe(l.Id)) {
      if (t.Status == STATUS_ABERTO) {
        abertas++;
      }
    }
    System.assertEquals(
      0,
      abertas,
      'Contato efetivado encerra as ligações pendentes dos dias 2 e 3.'
    );
  }
}
