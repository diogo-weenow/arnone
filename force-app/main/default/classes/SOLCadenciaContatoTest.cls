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

  // ======================================================================
  //  CLICKUP-9435 — CANAL E-MAIL
  //
  //  A cadência de e-mail reusa o MESMO núcleo da ligação, então o risco não
  //  está no caminho feliz — está no que os dois canais compartilham: a
  //  chave de idempotência, o lock do Lead, as inelegibilidades e as duas
  //  Validation Rules que separam os resultados. É isso que esta seção cobre.
  // ======================================================================

  private static final String CANAL_EMAIL = 'E-mail';
  private static final String STATUS_CANCELADA = 'Cancelada';
  private static final String RES_ENVIADO = 'Enviado';
  private static final String RES_NAO_ENVIADO = 'Não enviado';
  private static final String MOTIVO_CONTATO_EFETIVADO = 'Contato efetivado';
  private static final String MOTIVO_OPT_OUT = 'Opt-out';
  private static final String RES_OPT_OUT = 'Opt-out';
  private static final String MOTIVO_PERDA = 'Negócio perdido';
  private static final String PRODUTO_RT = 'Recuperação Tributária';

  private static Integer seq = 0;
  private static String rnd() {
    seq++;
    return seq + 'x' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
  }

  /** Tarefas da cadência de um canal QUALQUER, ordenadas por dia. */
  private static List<Task> tarefasDe(Id leadId, String canal) {
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
        SOL_Resultado_Envio__c,
        SOL_Motivo_Cancelamento__c,
        SOL_Cancelada_Por_Perda__c,
        SOL_Canal_Contato__c,
        SOL_Dia_Cadencia__c,
        SOL_Ciclo_Contato__c
      FROM Task
      WHERE WhoId = :leadId AND SOL_Canal_Contato__c = :canal
      ORDER BY SOL_Dia_Cadencia__c ASC, CreatedDate ASC
    ];
  }

  private static List<Task> emailsDe(Id leadId) {
    return tarefasDe(leadId, CANAL_EMAIL);
  }

  private static List<Task> tarefasDoDia(Id leadId, String canal, Integer dia) {
    List<Task> filtradas = new List<Task>();
    for (Task t : tarefasDe(leadId, canal)) {
      if (
        t.SOL_Dia_Cadencia__c != null &&
        t.SOL_Dia_Cadencia__c.intValue() == dia
      ) {
        filtradas.add(t);
      }
    }
    return filtradas;
  }

  private static List<Task> emailsDoDia(Id leadId, Integer dia) {
    return tarefasDoDia(leadId, CANAL_EMAIL, dia);
  }

  /** A outra porta pública: mesmo DTO, mesmo núcleo, canal E-mail. */
  private static SOLCadenciaContatoService.Resultado criarEmail(
    List<SOLCadenciaContatoService.Solicitacao> pedidos
  ) {
    return SOLCadenciaContatoService.criarEmails(pedidos);
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

  /**
   * Usuário de perfil STANDARD — e não o perfil de quem roda o teste. FLS
   * efetiva medida sobre um administrador não mede nada: ele vê tudo pelo
   * perfil, independente do permission set.
   */
  private static User usuarioStandard(String tag) {
    return new User(
      FirstName = 'Cad',
      LastName = 'Std ' + tag,
      Alias = ('cs' + tag).left(8),
      Email = 'cad.std.' + tag + '@arnone.invalid',
      Username = 'cad.std.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9435.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static Id permissionSetId(String nome) {
    return [SELECT Id FROM PermissionSet WHERE Name = :nome LIMIT 1].Id;
  }

  // ------------------------------------- criação, vencimento e classificação

  /** (1) Dias 1, 2 e 3 com o vencimento EXATO que o motor informou. */
  @IsTest
  static void emailDosTresDiasComVencimentoExato() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Map<Integer, Date> venc = new Map<Integer, Date>{
      1 => Date.today().addDays(3),
      2 => Date.today().addDays(4),
      3 => Date.today().addDays(5)
    };

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 1, venc.get(1)),
        pedido(l.Id, 2, venc.get(2)),
        pedido(l.Id, 3, venc.get(3))
      }
    );
    Test.stopTest();

    System.assertEquals(3, r.criadas, 'Os três dias de e-mail são criados.');
    System.assertEquals(
      0,
      r.jaExistentes + r.ignoradas + r.comErro,
      'Nada ignorado, nada repetido, nada com erro.'
    );

    List<Task> es = emailsDe(l.Id);
    System.assertEquals(3, es.size(), 'Uma tarefa de e-mail por dia.');
    for (Task t : es) {
      Integer dia = t.SOL_Dia_Cadencia__c.intValue();
      System.assertEquals(
        venc.get(dia),
        t.ActivityDate,
        'O vencimento do dia ' +
          dia +
          ' é exatamente o recebido do motor — o e-mail não deriva data de prazo.'
      );
    }
  }

  /** (2) Canal, tipo, ciclo, dia, dono, status aberto e prazo NULO. */
  @IsTest
  static void emailNasceClassificadoComPrazoNulo() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];

    Test.startTest();
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    Task t = emailsDoDia(l.Id, 2)[0];
    System.assertEquals(CANAL_EMAIL, t.SOL_Canal_Contato__c, 'Canal "E-mail".');
    System.assertEquals(
      TIPO_CONTATO,
      t.SOL_Tipo_Tarefa__c,
      'Tipo "Contato" — é por ele que os cancelamentos automáticos alcançam a tarefa.'
    );
    System.assertEquals(2, t.SOL_Dia_Cadencia__c.intValue(), 'Dia da cadência gravado.');
    System.assertEquals(
      l.SOL_Data_Inicio_Ciclo_Contato__c,
      t.SOL_Ciclo_Contato__c,
      'Ciclo congelado a partir do Lead.'
    );
    System.assertEquals(l.Id, t.WhoId, 'Vinculada ao Lead.');
    System.assertEquals(l.OwnerId, t.OwnerId, 'Do proprietário ATUAL do Lead.');
    System.assertEquals(STATUS_ABERTO, t.Status, 'Nasce aberta.');
    System.assertEquals(
      null,
      t.SOL_Prazo_Contato__c,
      'E-mail não tem SLA em minutos úteis: o prazo é nulo — e é isso que o mantém fora da VR de ligação.'
    );
    System.assertEquals(null, t.SOL_Resultado_Envio__c, 'Resultado do envio nasce vazio.');
    System.assertEquals(
      null,
      t.SOL_Resultado_Contato__c,
      'E o resultado de LIGAÇÃO nunca é preenchido aqui.'
    );
    System.assertNotEquals(null, t.Subject, 'Tem rótulo visível para o vendedor.');
  }

  /**
   * (1) O dia 1 do e-mail EXIGE vencimento. A isenção do dia 1 existe apenas na
   * ligação, onde a data é derivada dos 5 minutos úteis da atribuição. Sem este
   * recorte o e-mail do dia 1 nasceria com ActivityDate nulo.
   */
  @IsTest
  static void emailDia1SemVencimentoEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 1, null) }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Dia 1 de e-mail sem vencimento não cria nada.');
    System.assertEquals(1, r.ignoradas, 'É ignorado, não é erro.');
    System.assertEquals(0, emailsDe(l.Id).size(), 'Nenhuma tarefa de e-mail gravada.');
    System.assertEquals(
      1,
      ligacoesDoDia(l.Id, 1).size(),
      'E a ligação do dia 1, que segue derivando a data do prazo, continua intacta.'
    );
  }

  /** (1) Dias válidos são 1 a 3; qualquer outro pedido é ignorado. */
  @IsTest
  static void emailComDiaForaDaFaixaEhIgnorado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v = Date.today().addDays(4);

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 0, v),
        pedido(l.Id, 4, v),
        pedido(l.Id, null, v),
        pedido(null, 2, v)
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Nenhum pedido fora de 1..3 cria tarefa.');
    System.assertEquals(4, r.ignoradas, 'Os quatro pedidos são ignorados.');
    System.assertEquals(0, emailsDe(l.Id).size(), 'Nada gravado.');
  }

  /** (1) Lista nula ou vazia devolve resultado zerado sem tocar no banco. */
  @IsTest
  static void listaNulaOuVaziaDeEmailsDevolveZerado() {
    Test.startTest();
    Integer antes = Limits.getQueries();
    SOLCadenciaContatoService.Resultado nulo = criarEmail(null);
    SOLCadenciaContatoService.Resultado vazio = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>()
    );
    Integer delta = Limits.getQueries() - antes;
    Test.stopTest();

    System.assertEquals(
      0,
      nulo.criadas + nulo.jaExistentes + nulo.ignoradas + nulo.comErro,
      'Lista nula devolve resultado zerado.'
    );
    System.assertEquals(
      0,
      vazio.criadas + vazio.jaExistentes + vazio.ignoradas + vazio.comErro,
      'Lista vazia devolve resultado zerado.'
    );
    System.assertEquals(0, delta, 'Sem entrada não há consulta.');
  }

  // ------------------------------- idempotência e coexistência entre canais

  /** (3) Replay do mesmo pedido não duplica. */
  @IsTest
  static void reprocessarEmailNaoDuplica() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v = Date.today().addDays(4);
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v) }
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v) }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'O replay não cria.');
    System.assertEquals(1, r.jaExistentes, 'O dia já estava ocupado.');
    System.assertEquals(1, emailsDoDia(l.Id, 2).size(), 'Continua exatamente uma.');
  }

  /** (3) E-mail já CONCLUÍDO continua ocupando a chave do dia. */
  @IsTest
  static void emailConcluidoContinuaOcupandoODia() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v = Date.today().addDays(4);
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v) }
    );
    Task t = emailsDoDia(l.Id, 2)[0];
    t.SOL_Resultado_Envio__c = RES_ENVIADO;
    t.Status = STATUS_CONCLUIDO;
    update t;

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v) }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Tarefa concluída não é recriada.');
    System.assertEquals(1, r.jaExistentes, 'Ela segue ocupando o dia.');
    System.assertEquals(1, emailsDoDia(l.Id, 2).size(), 'Uma só no dia.');
  }

  /** (3) E-mail CANCELADO continua ocupando a chave do dia. */
  @IsTest
  static void emailCanceladoContinuaOcupandoODia() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v = Date.today().addDays(5);
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 3, v) }
    );
    Task t = emailsDoDia(l.Id, 3)[0];
    t.Status = STATUS_CANCELADA;
    t.SOL_Motivo_Cancelamento__c = MOTIVO_CONTATO_EFETIVADO;
    update t;

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 3, v) }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Tarefa cancelada não é recriada.');
    System.assertEquals(1, r.jaExistentes, 'Ela segue ocupando o dia.');
    System.assertEquals(1, emailsDoDia(l.Id, 3).size(), 'Uma só no dia.');
  }

  /** (3) Duplicata dentro do MESMO lote — antes de qualquer gravação. */
  @IsTest
  static void duplicataDeEmailNoMesmoLoteNaoDuplica() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v = Date.today().addDays(4);

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, v),
        pedido(l.Id, 2, v),
        pedido(l.Id, 2, v)
      }
    );
    Test.stopTest();

    System.assertEquals(1, r.criadas, 'Só o primeiro do lote cria.');
    System.assertEquals(2, r.jaExistentes, 'Os outros dois são duplicata.');
    System.assertEquals(1, emailsDoDia(l.Id, 2).size(), 'Uma tarefa no dia.');
  }

  /**
   * (4) Ligação e e-mail COEXISTEM no mesmo Lead, ciclo e dia. Antes do 9435 a
   * chave era Lead + ciclo + dia: a ligação do dia 2 bloquearia o e-mail do
   * dia 2. O canal na chave é o que permite os dois no mesmo dia.
   */
  @IsTest
  static void ligacaoEEmailCoexistemNoMesmoDia() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v = Date.today().addDays(4);
    criar(new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v) });
    System.assertEquals(
      1,
      ligacoesDoDia(l.Id, 2).size(),
      'Pré-condição: a ligação do dia 2 existe.'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v) }
    );
    Test.stopTest();

    System.assertEquals(1, r.criadas, 'A ligação do mesmo dia NÃO bloqueia o e-mail.');
    System.assertEquals(0, r.jaExistentes, 'As chaves são distintas por canal.');
    System.assertEquals(1, ligacoesDoDia(l.Id, 2).size(), 'A ligação segue única.');
    System.assertEquals(1, emailsDoDia(l.Id, 2).size(), 'E o e-mail também.');

    Task ligacao = ligacoesDoDia(l.Id, 2)[0];
    Task email = emailsDoDia(l.Id, 2)[0];
    System.assertNotEquals(ligacao.Id, email.Id, 'São duas Tasks diferentes.');
    System.assertEquals(
      ligacao.SOL_Ciclo_Contato__c,
      email.SOL_Ciclo_Contato__c,
      'Mesmo Lead, mesmo ciclo, mesmo dia: só o canal difere.'
    );
    System.assertEquals(
      ligacao.SOL_Dia_Cadencia__c,
      email.SOL_Dia_Cadencia__c,
      'O dia é o mesmo nas duas.'
    );
  }

  /**
   * (5) Projeção do canal na consulta de chaves — o inverso do teste acima.
   * `chavesExistentes` filtra por canal E monta a chave com o canal LIDO da
   * linha. Se montasse com uma constante presumida, as ligações existentes
   * apareceriam como chaves de e-mail e bloqueariam a criação SILENCIOSAMENTE:
   * sem erro, contabilizada como `jaExistentes`.
   */
  @IsTest
  static void projecaoDoCanalNaConsultaDeChavesExistentes() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v2 = Date.today().addDays(4);
    Date v3 = Date.today().addDays(5);
    // Dia 1 já vem da distribuição; dias 2 e 3 pelo motor. Todos os três dias
    // de LIGAÇÃO ocupados.
    criar(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, v2),
        pedido(l.Id, 3, v3)
      }
    );
    System.assertEquals(3, ligacoesDe(l.Id).size(), 'Pré-condição: 3 ligações.');

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 1, Date.today().addDays(3)),
        pedido(l.Id, 2, v2),
        pedido(l.Id, 3, v3)
      }
    );
    Test.stopTest();

    System.assertEquals(
      3,
      r.criadas,
      'Nenhuma das 3 ligações pode ocupar uma chave de e-mail.'
    );
    System.assertEquals(0, r.jaExistentes, 'Nenhuma chave de e-mail estava ocupada.');
    System.assertEquals(3, emailsDe(l.Id).size(), 'Três e-mails.');
    System.assertEquals(3, ligacoesDe(l.Id).size(), 'As ligações seguem intactas.');
    for (Task t : emailsDe(l.Id)) {
      System.assertEquals(CANAL_EMAIL, t.SOL_Canal_Contato__c, 'Todas do canal E-mail.');
    }

    // E o simétrico: com os três dias de e-mail ocupados, a ligação não é
    // bloqueada por eles.
    SOLCadenciaContatoService.Resultado rLigacao = criar(
      new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v2) }
    );
    System.assertEquals(
      1,
      rLigacao.jaExistentes,
      'A ligação do dia 2 é bloqueada pela LIGAÇÃO do dia 2, não pelo e-mail.'
    );
    System.assertEquals(0, rLigacao.criadas, 'E nada novo é criado.');
  }

  // ------------------------------------------------- bulk e inelegibilidades

  /** (6) Lote grande: as consultas não escalam — nada de SOQL/DML em laço. */
  @IsTest
  static void loteDeEmailsNaoEscalaConsultas() {
    montarCenario(2);
    List<Lead> leads = leadsDistribuidos(5);
    Date d2 = Date.today().addDays(4);
    Date d3 = Date.today().addDays(5);

    List<SOLCadenciaContatoService.Solicitacao> umSo = new List<SOLCadenciaContatoService.Solicitacao>{
      pedido(leads[0].Id, 2, d2)
    };
    List<SOLCadenciaContatoService.Solicitacao> lote = new List<SOLCadenciaContatoService.Solicitacao>();
    for (Integer i = 1; i < leads.size(); i++) {
      lote.add(pedido(leads[i].Id, 2, d2));
      lote.add(pedido(leads[i].Id, 3, d3));
    }

    Test.startTest();
    Integer qAntesUm = Limits.getQueries();
    Integer dAntesUm = Limits.getDmlStatements();
    SOLCadenciaContatoService.Resultado rUm = criarEmail(umSo);
    Integer qUm = Limits.getQueries() - qAntesUm;
    Integer dUm = Limits.getDmlStatements() - dAntesUm;

    Integer qAntesLote = Limits.getQueries();
    Integer dAntesLote = Limits.getDmlStatements();
    SOLCadenciaContatoService.Resultado rLote = criarEmail(lote);
    Integer qLote = Limits.getQueries() - qAntesLote;
    Integer dLote = Limits.getDmlStatements() - dAntesLote;
    Test.stopTest();

    System.assertEquals(1, rUm.criadas, 'Um Lead, um e-mail.');
    System.assertEquals(8, rLote.criadas, '4 Leads e 2 dias cada.');
    System.assertEquals(
      qUm,
      qLote,
      'As consultas não escalam com o tamanho do lote.'
    );
    System.assertEquals(
      dUm,
      dLote,
      'E o DML também não: um insert só, independente do lote.'
    );
    System.assert(qLote <= 3, 'O lote inteiro cabe em poucas consultas; usou ' + qLote);
    for (Integer i = 1; i < leads.size(); i++) {
      System.assertEquals(
        2,
        emailsDe(leads[i].Id).size(),
        'Cada Lead do lote recebeu os dois dias de e-mail.'
      );
    }
  }

  /** (7) Lead de outra BU é ignorado. */
  @IsTest
  static void emailIgnoraLeadDeOutraBU() {
    montarCenario(1);
    // Ciclo preenchido à mão para que a ÚNICA razão da recusa seja a BU.
    Lead outro = new Lead(
      LastName = 'Lead de outra BU',
      Company = 'Outra Empresa',
      Status = statusLead(),
      SOL_Data_Inicio_Ciclo_Contato__c = System.now()
    );
    insert outro;

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(outro.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      r.criadas,
      'Fora da Arnone Soluções não há cadência de e-mail.'
    );
    System.assertEquals(1, r.ignoradas, 'Ignorado, sem erro.');
    System.assertEquals(0, emailsDe(outro.Id).size(), 'Nada gravado.');
  }

  /** (7) Lead SOL sem ciclo aberto é ignorado. */
  @IsTest
  static void emailIgnoraLeadSemCiclo() {
    montarCenario(1);
    Lead semCiclo = leadsDistribuidos(1)[0];
    update new Lead(Id = semCiclo.Id, SOL_Data_Inicio_Ciclo_Contato__c = null);
    System.assertEquals(
      null,
      recarregar(semCiclo.Id).SOL_Data_Inicio_Ciclo_Contato__c,
      'Pré-condição: sem ciclo aberto.'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(semCiclo.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Sem ciclo não há cadência.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
  }

  /**
   * (7) Lead estacionado na FILA (fallback da distribuição) é ignorado: o dono
   * é um Group e Task.OwnerId exige User.
   */
  @IsTest
  static void emailIgnoraLeadEmFallbackNaFila() {
    Cenario c = montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    update new Lead(Id = l.Id, OwnerId = c.filaId);
    System.assertEquals(
      Group.SObjectType,
      recarregar(l.Id).OwnerId.getSObjectType(),
      'Pré-condição: o Lead está com a fila.'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Lead em fallback não recebe e-mail.');
    System.assertEquals(1, r.ignoradas, 'Ignorado, sem erro de DML.');
    System.assertEquals(0, emailsDe(l.Id).size(), 'Nada gravado.');
  }

  /** (7) Lead inexistente é ignorado. */
  @IsTest
  static void emailIgnoraLeadInexistente() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Id idRemovido = l.Id;
    delete l;

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(idRemovido, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Lead inexistente não gera tarefa.');
    System.assertEquals(1, r.ignoradas, 'Ignorado, sem erro.');
  }

  /** (7) Lead convertido é ignorado. */
  @IsTest
  static void emailIgnoraLeadConvertido() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    update new Lead(Id = l.Id, SOL_Status_Procuracao__c = 'Recebida');

    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1]
      .MasterLabel
    );
    System.assert(
      Database.convertLead(lc).isSuccess(),
      'Pré-condição: o Lead precisa converter.'
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Lead convertido não recebe e-mail.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
    System.assertEquals(0, emailsDoDia(l.Id, 2).size(), 'Nada criado.');
  }

  /** (7) Contato efetivado encerra a cadência: nenhum e-mail novo. */
  @IsTest
  static void emailIgnoraLeadComContatoEfetivado() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    update new Lead(Id = l.Id, SOL_Contato_Efetivado__c = true);

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      r.criadas,
      'Contato efetivado encerra a cadência: nada de e-mail novo.'
    );
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
  }

  /** (7) Opt-out encerra a cadência: nenhum e-mail novo. */
  @IsTest
  static void emailIgnoraLeadComOptOut() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    // Opt-out e motivo andam juntos (VR SOL_Desqualificacao_Coerente).
    update new Lead(
      Id = l.Id,
      SOL_Opt_Out__c = true,
      SOL_Motivo_Desqualificacao__c = MOTIVO_OPT_OUT
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Opt-out encerra a cadência.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
  }

  /** (7) Negócio perdido encerra a cadência: nenhum e-mail novo. */
  @IsTest
  static void emailIgnoraLeadComNegocioPerdido() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    update new Lead(
      Id = l.Id,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA
    );

    Test.startTest();
    SOLCadenciaContatoService.Resultado r = criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );
    Test.stopTest();

    System.assertEquals(0, r.criadas, 'Negócio perdido encerra a cadência.');
    System.assertEquals(1, r.ignoradas, 'Ignorado.');
    System.assertEquals(0, emailsDoDia(l.Id, 2).size(), 'Nada criado.');
  }

  // ------------------------- conclusão e isolamento dos dois resultados
  //
  //  Duas VRs novas, cada uma com um recorte próprio:
  //  SOL_Resultado_Envio_Obrigatorio  — não conclui e-mail sem resultado;
  //  SOL_Email_Sem_Resultado_Ligacao  — e-mail nunca recebe resultado de
  //                                     ligação, que é o gatilho de contato
  //                                     efetivado, opt-out e reatribuição.

  /** (8) Conclusão do e-mail sem resultado do envio é bloqueada. */
  @IsTest
  static void emailNaoConcluiSemResultadoDeEnvio() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );

    Test.startTest();
    Task t = emailsDoDia(l.Id, 2)[0];
    String erro = '';
    try {
      t.Status = STATUS_CONCLUIDO;
      update t;
    } catch (DmlException e) {
      erro = e.getMessage();
    }
    Test.stopTest();

    System.assert(
      erro.contains('resultado do envio'),
      'Concluir e-mail sem resultado do envio tem de ser bloqueado pela VR de ENVIO. Recebido: ' +
        erro
    );
    System.assert(
      !erro.contains('resultado da ligação'),
      'E não pela VR de ligação: o e-mail não tem prazo de contato nem canal Ligação. Recebido: ' +
        erro
    );
    System.assertEquals(
      STATUS_ABERTO,
      emailsDoDia(l.Id, 2)[0].Status,
      'A tarefa continua aberta.'
    );
  }

  /** (9) Conclusão permitida com "Enviado" e com "Não enviado". */
  @IsTest
  static void emailConcluiComEnviadoEComNaoEnviado() {
    montarCenario(2);
    List<Lead> leads = leadsDistribuidos(2);
    for (Lead l : leads) {
      criarEmail(
        new List<SOLCadenciaContatoService.Solicitacao>{
          pedido(l.Id, 2, Date.today().addDays(4))
        }
      );
    }
    List<String> resultados = new List<String>{ RES_ENVIADO, RES_NAO_ENVIADO };

    Test.startTest();
    for (Integer i = 0; i < leads.size(); i++) {
      Task t = emailsDoDia(leads[i].Id, 2)[0];
      t.SOL_Resultado_Envio__c = resultados[i];
      t.Status = STATUS_CONCLUIDO;
      update t;
    }
    Test.stopTest();

    for (Integer i = 0; i < leads.size(); i++) {
      Task t = emailsDoDia(leads[i].Id, 2)[0];
      System.assertEquals(
        STATUS_CONCLUIDO,
        t.Status,
        'O e-mail conclui com o resultado "' + resultados[i] + '".'
      );
      System.assertEquals(
        resultados[i],
        t.SOL_Resultado_Envio__c,
        'O resultado do envio é preservado.'
      );
      System.assertEquals(
        CANAL_EMAIL,
        t.SOL_Canal_Contato__c,
        'A classificação sobrevive à conclusão.'
      );
    }
  }

  /** (10) Resultado de LIGAÇÃO é rejeitado numa tarefa de e-mail. */
  @IsTest
  static void emailRejeitaResultadoDeLigacao() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );
    Id emailId = emailsDoDia(l.Id, 2)[0].Id;
    List<String> tentados = new List<String>{
      RES_ATENDEU,
      RES_NAO_ATENDEU,
      RES_NAO_FOI_POSSIVEL,
      RES_OPT_OUT
    };

    Test.startTest();
    List<String> erros = new List<String>();
    for (String res : tentados) {
      try {
        update new Task(Id = emailId, SOL_Resultado_Contato__c = res);
        erros.add('');
      } catch (DmlException e) {
        erros.add(e.getMessage());
      }
    }
    Test.stopTest();

    for (Integer i = 0; i < tentados.size(); i++) {
      System.assert(
        erros[i].contains('tarefa de e-mail'),
        'O resultado de ligação "' +
          tentados[i] +
          '" não pode entrar em tarefa de e-mail. Recebido: ' +
          erros[i]
      );
    }
    System.assertEquals(
      null,
      emailsDoDia(l.Id, 2)[0].SOL_Resultado_Contato__c,
      'O campo de ligação segue vazio na tarefa de e-mail.'
    );
  }

  /** (14) A VR de envio NÃO alcança a tarefa de LIGAÇÃO — regressão do 9434. */
  @IsTest
  static void vrDeEnvioNaoAlcancaTarefaDeLigacao() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    Date v = Date.today().addDays(4);
    criar(new List<SOLCadenciaContatoService.Solicitacao>{ pedido(l.Id, 2, v) });

    Test.startTest();
    // Dia 1 (com prazo) e dia 2 (sem prazo): os dois caminhos da VR antiga.
    for (Integer dia : new List<Integer>{ 1, 2 }) {
      Task t = tarefasDoDia(l.Id, CANAL_LIGACAO, dia)[0];
      t.SOL_Resultado_Contato__c = RES_NAO_ATENDEU;
      t.Status = STATUS_CONCLUIDO;
      update t;
    }
    Test.stopTest();

    for (Integer dia : new List<Integer>{ 1, 2 }) {
      Task t = tarefasDoDia(l.Id, CANAL_LIGACAO, dia)[0];
      System.assertEquals(
        STATUS_CONCLUIDO,
        t.Status,
        'A ligação do dia ' + dia + ' conclui com o resultado de LIGAÇÃO.'
      );
      System.assertEquals(
        null,
        t.SOL_Resultado_Envio__c,
        'E sem nunca precisar do resultado do envio.'
      );
    }
  }

  /**
   * (12) A VR de envio NÃO bloqueia o cancelamento: o campo é exigido apenas em
   * "Completed". Cancelar por contato efetivado, opt-out ou perda fecha a
   * tarefa sem resultado.
   */
  @IsTest
  static void vrDeEnvioNaoBloqueiaCancelamento() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );

    Test.startTest();
    Task t = emailsDoDia(l.Id, 2)[0];
    t.Status = STATUS_CANCELADA;
    t.SOL_Motivo_Cancelamento__c = MOTIVO_CONTATO_EFETIVADO;
    update t;
    Test.stopTest();

    Task depois = emailsDoDia(l.Id, 2)[0];
    System.assertEquals(
      STATUS_CANCELADA,
      depois.Status,
      'Cancelar não exige resultado do envio.'
    );
    System.assertEquals(
      null,
      depois.SOL_Resultado_Envio__c,
      'E o resultado fica vazio, como a automação deixa.'
    );
  }

  /**
   * (8) A VR de envio é isolada pelo canal E pelo dia: uma tarefa de contato
   * sem os classificadores da cadência não é alcançada.
   */
  @IsTest
  static void vrDeEnvioSoAlcancaEmailDaCadencia() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];

    Test.startTest();
    // Tarefa de e-mail SEM dia de cadência: fora do escopo da regra.
    Task solta = new Task(
      Subject = 'E-mail manual',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = STATUS_ABERTO,
      SOL_Tipo_Tarefa__c = TIPO_CONTATO,
      SOL_Canal_Contato__c = CANAL_EMAIL
    );
    insert solta;
    update new Task(Id = solta.Id, Status = STATUS_CONCLUIDO);
    Test.stopTest();

    System.assertEquals(
      STATUS_CONCLUIDO,
      [SELECT Status FROM Task WHERE Id = :solta.Id].Status,
      'Sem dia de cadência a VR de envio não se aplica: a regra é da tarefa DIÁRIA.'
    );
  }

  // ---------------------------- ausência de efeitos e cancelamentos herdados

  /**
   * (11) Concluir os TRÊS e-mails do ciclo não sinaliza contato efetivado, não
   * desqualifica por opt-out e não move a reatribuição — três resultados
   * negativos em LIGAÇÃO trocariam o vendedor.
   */
  @IsTest
  static void concluirEmailsNaoSinalizaNadaNoLead() {
    montarCenario(3);
    Lead l = leadsDistribuidos(1)[0];
    Id donoOriginal = l.OwnerId;
    Datetime cicloOriginal = l.SOL_Data_Inicio_Ciclo_Contato__c;
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 1, Date.today().addDays(3)),
        pedido(l.Id, 2, Date.today().addDays(4)),
        pedido(l.Id, 3, Date.today().addDays(5))
      }
    );
    System.assertEquals(3, emailsDe(l.Id).size(), 'Pré-condição: três e-mails.');

    Test.startTest();
    for (Task t : emailsDe(l.Id)) {
      t.SOL_Resultado_Envio__c = RES_NAO_ENVIADO;
      t.Status = STATUS_CONCLUIDO;
      update t;
    }
    Test.stopTest();

    Lead depois = [
      SELECT
        OwnerId,
        Status,
        SOL_Contato_Efetivado__c,
        SOL_Data_Contato_Efetivado__c,
        SOL_Opt_Out__c,
        SOL_Motivo_Desqualificacao__c,
        SOL_Data_Inicio_Ciclo_Contato__c,
        SOL_Quantidade_Reatribuicoes__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    System.assert(
      depois.SOL_Contato_Efetivado__c != true,
      'Enviar e-mail NÃO é contato efetivado.'
    );
    System.assertEquals(
      null,
      depois.SOL_Data_Contato_Efetivado__c,
      'E não estampa a data do contato efetivado.'
    );
    System.assert(depois.SOL_Opt_Out__c != true, 'E não é opt-out.');
    System.assertNotEquals(
      'Desqualificado',
      depois.Status,
      'O Lead não é desqualificado por e-mail nenhum.'
    );
    System.assertEquals(donoOriginal, depois.OwnerId, 'Nenhuma reatribuição.');
    System.assertEquals(
      cicloOriginal,
      depois.SOL_Data_Inicio_Ciclo_Contato__c,
      'E o ciclo não foi reiniciado.'
    );
    System.assert(
      depois.SOL_Quantidade_Reatribuicoes__c == null ||
      depois.SOL_Quantidade_Reatribuicoes__c == 0,
      'O contador de reatribuições não se move com e-mail.'
    );
  }

  /**
   * (11) O e-mail não CONTA como tentativa. Três e-mails concluídos mais UMA
   * ligação negativa somam 1 tentativa, não 4: se a contagem lesse tarefas de
   * contato sem olhar o resultado de ligação, o vendedor trocaria aqui.
   */
  @IsTest
  static void emailNaoContaComoTentativaDeContato() {
    montarCenario(3);
    Lead l = leadsDistribuidos(1)[0];
    Id donoOriginal = l.OwnerId;
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 1, Date.today().addDays(3)),
        pedido(l.Id, 2, Date.today().addDays(4)),
        pedido(l.Id, 3, Date.today().addDays(5))
      }
    );
    for (Task t : emailsDe(l.Id)) {
      t.SOL_Resultado_Envio__c = RES_NAO_ENVIADO;
      t.Status = STATUS_CONCLUIDO;
      update t;
    }

    Test.startTest();
    // A ÚNICA tentativa de verdade: a ligação do dia 1, negativa.
    Task ligacao = ligacoesDoDia(l.Id, 1)[0];
    ligacao.SOL_Resultado_Contato__c = RES_NAO_ATENDEU;
    ligacao.Status = STATUS_CONCLUIDO;
    update ligacao;
    Test.stopTest();

    System.assertEquals(
      donoOriginal,
      recarregar(l.Id).OwnerId,
      'Uma tentativa negativa não reatribui — os três e-mails não somam à contagem.'
    );
  }

  /**
   * (12) Contato efetivado cancela o e-mail pendente — sem código novo: o
   * cancelamento do 9417 filtra por SOL_Tipo_Tarefa__c = "Contato" e não olha
   * canal, e a tarefa de e-mail nasce com esse tipo.
   */
  @IsTest
  static void contatoEfetivadoCancelaEmailPendente() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4)),
        pedido(l.Id, 3, Date.today().addDays(5))
      }
    );

    Test.startTest();
    Task dia1 = ligacoesDoDia(l.Id, 1)[0];
    dia1.SOL_Resultado_Contato__c = RES_ATENDEU;
    dia1.Status = STATUS_CONCLUIDO;
    update dia1;
    Test.stopTest();

    System.assertEquals(
      true,
      [SELECT SOL_Contato_Efetivado__c FROM Lead WHERE Id = :l.Id]
        .SOL_Contato_Efetivado__c,
      'Pré-condição: o contato foi efetivado.'
    );
    List<Task> es = emailsDe(l.Id);
    System.assertEquals(2, es.size(), 'Os dois e-mails continuam existindo.');
    for (Task t : es) {
      System.assertEquals(
        STATUS_CANCELADA,
        t.Status,
        'O e-mail pendente do dia ' + t.SOL_Dia_Cadencia__c + ' é cancelado.'
      );
      System.assertEquals(
        MOTIVO_CONTATO_EFETIVADO,
        t.SOL_Motivo_Cancelamento__c,
        'Com o motivo da automação existente.'
      );
      System.assertEquals(
        null,
        t.SOL_Resultado_Envio__c,
        'Cancelado não é enviado: o resultado do envio fica vazio.'
      );
    }
  }

  /** (12) Opt-out cancela o e-mail pendente. */
  @IsTest
  static void optOutCancelaEmailPendente() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );

    Test.startTest();
    Task dia1 = ligacoesDoDia(l.Id, 1)[0];
    dia1.SOL_Resultado_Contato__c = RES_OPT_OUT;
    dia1.Status = STATUS_CONCLUIDO;
    update dia1;
    Test.stopTest();

    System.assertEquals(
      true,
      [SELECT SOL_Opt_Out__c FROM Lead WHERE Id = :l.Id].SOL_Opt_Out__c,
      'Pré-condição: o opt-out foi registrado.'
    );
    Task email = emailsDoDia(l.Id, 2)[0];
    System.assertEquals(
      STATUS_CANCELADA,
      email.Status,
      'O opt-out cancela o e-mail pendente.'
    );
    System.assertEquals(
      MOTIVO_OPT_OUT,
      email.SOL_Motivo_Cancelamento__c,
      'Com o motivo do opt-out.'
    );
  }

  /** (12) Negócio perdido cancela o e-mail pendente e o marca como tal. */
  @IsTest
  static void negocioPerdidoCancelaEmailPendente() {
    montarCenario(1);
    Lead l = leadsDistribuidos(1)[0];
    // O encerramento por perda (9425) exige produto de interesse SOL.
    update new Lead(Id = l.Id, SOL_Produto_Interesse__c = PRODUTO_RT);
    criarEmail(
      new List<SOLCadenciaContatoService.Solicitacao>{
        pedido(l.Id, 2, Date.today().addDays(4))
      }
    );

    Test.startTest();
    update new Lead(
      Id = l.Id,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA
    );
    Test.stopTest();

    Task email = emailsDoDia(l.Id, 2)[0];
    System.assertEquals(
      STATUS_CANCELADA,
      email.Status,
      'A perda do negócio cancela o e-mail pendente.'
    );
    System.assertEquals(
      MOTIVO_PERDA,
      email.SOL_Motivo_Cancelamento__c,
      'Com o motivo da perda.'
    );
    System.assertEquals(
      true,
      email.SOL_Cancelada_Por_Perda__c,
      'E com a marca do encerramento automático por perda.'
    );
  }

  // ---------------------------------------------- FLS do resultado do envio

  /** (13) FLS ESTRUTURAL: o que os dois permission sets declaram. */
  @IsTest
  static void flsEstruturalDoResultadoEnvio() {
    Map<String, FieldPermissions> porPs = new Map<String, FieldPermissions>();
    for (FieldPermissions fp : [
      SELECT PermissionsRead, PermissionsEdit, Parent.Name
      FROM FieldPermissions
      WHERE
        Field = 'Task.SOL_Resultado_Envio__c'
        AND Parent.Name IN ('PS_SOL_Comercial', 'PS_SOL_Distribuicao_Admin')
    ]) {
      porPs.put(fp.Parent.Name, fp);
    }

    System.assert(
      porPs.containsKey('PS_SOL_Comercial'),
      'PS_SOL_Comercial declara o resultado do envio.'
    );
    System.assert(
      porPs.get('PS_SOL_Comercial').PermissionsRead,
      'Vendedor lê o resultado do envio.'
    );
    System.assert(
      porPs.get('PS_SOL_Comercial').PermissionsEdit,
      'Vendedor EDITA: é ele quem preenche ao concluir.'
    );

    System.assert(
      porPs.containsKey('PS_SOL_Distribuicao_Admin'),
      'PS_SOL_Distribuicao_Admin declara o resultado do envio.'
    );
    System.assert(
      porPs.get('PS_SOL_Distribuicao_Admin').PermissionsRead,
      'Gestor lê o resultado do envio.'
    );
    System.assert(
      !porPs.get('PS_SOL_Distribuicao_Admin').PermissionsEdit,
      'Gestor apenas LÊ: quem registra o envio é o vendedor.'
    );
  }

  /**
   * (13) FLS EFETIVA, em runtime, sobre usuários de perfil Standard: o
   * vendedor edita o resultado do envio, o gestor só lê, e os classificadores
   * de canal e dia seguem somente leitura para os dois.
   */
  @IsTest
  static void flsEfetivaDoResultadoEnvio() {
    User vendedor = usuarioStandard('v' + rnd().left(3));
    User gestor = usuarioStandard('g' + rnd().left(3));
    System.runAs(contextoAtual()) {
      insert new List<User>{ vendedor, gestor };
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = vendedor.Id,
          PermissionSetId = permissionSetId('PS_SOL_Comercial')
        ),
        new PermissionSetAssignment(
          AssigneeId = gestor.Id,
          PermissionSetId = permissionSetId('PS_SOL_Distribuicao_Admin')
        )
      };
    }

    Test.startTest();
    System.runAs(new User(Id = vendedor.Id)) {
      Schema.DescribeFieldResult envio = Task.SOL_Resultado_Envio__c.getDescribe();
      System.assert(envio.isAccessible(), 'Vendedor lê o resultado do envio.');
      System.assert(envio.isUpdateable(), 'Vendedor EDITA o resultado do envio.');
      System.assert(
        !Task.SOL_Canal_Contato__c.getDescribe().isUpdateable(),
        'Vendedor não edita o canal — é classificador da automação.'
      );
      System.assert(
        !Task.SOL_Dia_Cadencia__c.getDescribe().isUpdateable(),
        'Vendedor não edita o dia da cadência.'
      );
    }
    System.runAs(new User(Id = gestor.Id)) {
      Schema.DescribeFieldResult envio = Task.SOL_Resultado_Envio__c.getDescribe();
      System.assert(envio.isAccessible(), 'Gestor lê o resultado do envio.');
      System.assert(
        !envio.isUpdateable(),
        'Gestor NÃO edita o resultado do envio.'
      );
      System.assert(
        !Task.SOL_Canal_Contato__c.getDescribe().isUpdateable(),
        'E também não edita o canal.'
      );
    }
    Test.stopTest();
  }
}
