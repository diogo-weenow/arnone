/**
 * CLICKUP-9400 — Testes da reatribuição de Leads SOL por falta de contato.
 *
 * Reutiliza a arquitetura do CLICKUP-9394 (singleton, lock, fila Fila_Leads_SOL,
 * roster de membros diretos ativos, ponteiro global). Os Flows
 * SOL_Distribuir_Lead e SOL_Reatribuir_Por_Falta_Contato estão ATIVOS: inserir
 * um Lead SOL já dispara a distribuição inicial e concluir uma Task com
 * "Sem sucesso" já dispara a avaliação de reatribuição. Os testes convivem com a
 * automação real (sem bypass) e ainda chamam o serviço diretamente para deixar
 * a intenção explícita — a operação é idempotente.
 *
 * Nenhum teste depende de permission set: o serviço roda em contexto de sistema.
 */
@IsTest
private class SOLReatribuicaoContatoServiceTest {
  private static final String FILA_SINTETICA = 'RR_Reatrib_SOL_9400';
  private static final String CNPJ = '11222333000181';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User vendedor(Integer i) {
    return new User(
      FirstName = 'RR',
      LastName = 'ReatVend ' + i,
      Alias = ('rrt' + i).left(8),
      Email = 'rr.rt' + i + '@arnone.invalid',
      Username = 'rr.rt' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9400.test.invalid',
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

  private static Cenario montarCenario(Integer qtdVendedores) {
    Cenario c = new Cenario();
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      vs.add(vendedor(i));
    }
    System.runAs(contextoAtual()) {
      if (!vs.isEmpty()) {
        insert vs;
      }
      Group fila = new Group(
        Name = 'RR Reatrib SOL 9400',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      c.filaId = fila.Id;
      List<GroupMember> gms = new List<GroupMember>();
      for (User v : vs) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = v.Id));
      }
      if (!gms.isEmpty()) {
        insert gms;
      }
    }
    for (User v : vs) {
      c.vendedores.add(v.Id);
    }
    c.vendedores.sort();
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    return c;
  }

  private static Id rtSOL() {
    return Lead.SObjectType.getDescribe()
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
   * Insere um Lead SOL — o Flow ativo o distribui e abre o ciclo de contato.
   * A Task "1ª Ligação" da distribuição inicial é removida para os testes de
   * reatribuição contarem só a Task que a reatribuição cria.
   */
  private static Lead novoLeadSOLDistribuido(String nome) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = nome,
      Company = 'C',
      Status = statusLead(),
      CNPJ__c = CNPJ
    );
    insert l;
    delete [
      SELECT Id
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
    ];
    return recarregar(l.Id);
  }

  private static Lead novoLeadSemRT(String nome) {
    Lead l = new Lead(LastName = nome, Company = 'C', Status = statusLead());
    insert l;
    return recarregar(l.Id);
  }

  private static Lead recarregar(Id id) {
    return [
      SELECT
        Id,
        OwnerId,
        IsConverted,
        SOL_Status_Distribuicao__c,
        SOL_Status_Reatribuicao__c,
        SOL_Quantidade_Reatribuicoes__c,
        SOL_Data_Inicio_Ciclo_Contato__c,
        SOL_Data_Ultima_Reatribuicao__c,
        SOL_Motivo_Ultima_Reatribuicao__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  // CLICKUP-9396: "Não atendeu" e "Não foi possível ligar" contam como tentativa
  // negativa; "Atendeu" = contato efetivado (bloqueia a reatribuição do ciclo).
  private static void tasksResultado(Id leadId, Integer qtd, String resultado) {
    List<Task> ts = new List<Task>();
    for (Integer i = 0; i < qtd; i++) {
      ts.add(
        new Task(
          WhoId = leadId,
          Subject = 'Tentativa de contato',
          Status = 'Completed',
          ActivityDate = Date.today(),
          SOL_Resultado_Contato__c = resultado
        )
      );
    }
    insert ts;
  }

  private static void tasksNegativas(Id leadId, Integer qtd) {
    tasksResultado(leadId, qtd, 'Não atendeu');
  }

  private static void taskAtendeu(Id leadId) {
    insert new Task(
      WhoId = leadId,
      Subject = 'Contato efetivado',
      Status = 'Completed',
      ActivityDate = Date.today(),
      SOL_Resultado_Contato__c = 'Atendeu'
    );
  }

  private static SOL_Distribuicao_Estado__c estado() {
    return [
      SELECT Ultimo_Usuario__c, Total_Distribuido__c
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
  }

  private static void ponteiro(Id usuario) {
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
    e.Ultimo_Usuario__c = usuario;
    update e;
  }

  private static void killSwitch() {
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
    e.Ativo__c = false;
    update e;
  }

  private static List<Task> primeirasLigacoes(Id leadId) {
    return [
      SELECT OwnerId, Status, SOL_Prazo_Contato__c
      FROM Task
      WHERE WhoId = :leadId AND Subject = '1ª Ligação'
    ];
  }

  private static Integer totalTasks(Id leadId) {
    return [SELECT COUNT() FROM Task WHERE WhoId = :leadId];
  }

  // ============================================================ CONTAGEM

  @IsTest
  static void primeiraESegundaTentativaNaoReatribuem() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S1');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    tasksNegativas(l.Id, 2);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(ownerInicial, d.OwnerId, 'Owner não muda com 2 tentativas.');
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c);
    System.assertEquals('Em acompanhamento', d.SOL_Status_Reatribuicao__c);
  }

  @IsTest
  static void terceiraTentativaSemSucessoReatribui() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S2');
    Id ownerInicial = l.OwnerId; // c.vendedores[0]

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(ownerInicial, d.OwnerId, 'Owner mudou.');
    System.assert(c.vendedores.contains(d.OwnerId), 'Novo owner é vendedor da fila.');
    System.assertEquals(c.vendedores[1], d.OwnerId, 'Próximo do rodízio.');
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
    System.assertEquals('Reatribuido', d.SOL_Status_Reatribuicao__c);
    System.assertEquals(
      'Sem contato após 3 tentativas',
      d.SOL_Motivo_Ultima_Reatribuicao__c
    );
    System.assertNotEquals(null, d.SOL_Data_Ultima_Reatribuicao__c);
    System.assertEquals(
      c.vendedores[1],
      estado().Ultimo_Usuario__c,
      'Ponteiro global avançou.'
    );

    List<Task> pl = primeirasLigacoes(l.Id);
    System.assertEquals(1, pl.size(), 'Uma tarefa 1ª Ligação criada.');
    System.assertEquals(d.OwnerId, pl[0].OwnerId, 'Tarefa para o novo vendedor.');
    System.assertNotEquals(null, pl[0].SOL_Prazo_Contato__c);
  }

  @IsTest
  static void contatoComSucessoImpedeReatribuicao() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S3');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    taskAtendeu(l.Id); // contato efetivado no ciclo
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(ownerInicial, d.OwnerId, 'Sucesso no ciclo impede a troca.');
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c);
  }

  @IsTest
  static void tarefasAnterioresAoCicloNaoContam() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S4');
    Id ownerInicial = l.OwnerId;

    // Ciclo começa no FUTURO: as tarefas a seguir são "anteriores ao ciclo".
    update new Lead(
      Id = l.Id,
      SOL_Data_Inicio_Ciclo_Contato__c = System.now().addMinutes(30)
    );

    Test.startTest();
    tasksNegativas(l.Id, 3); // Flow dispara mas nada conta (antes do ciclo)
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      ownerInicial,
      d.OwnerId,
      'Tarefas concluídas antes do início do ciclo não contam.'
    );
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c);
  }

  @IsTest
  static void novoCicloExigeOutrasTresTentativas() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S5');

    // 1ª troca real: 3 tarefas sem sucesso.
    tasksNegativas(l.Id, 3);
    System.assertEquals(1, recarregar(l.Id).SOL_Quantidade_Reatribuicoes__c);

    // Simula um novo ciclo limpo (o relógio do teste é congelado, então as
    // tarefas do ciclo anterior seriam re-contadas se ficassem visíveis —
    // aqui elas são removidas só para isolar a contagem do novo ciclo).
    delete [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject != '1ª Ligação'];
    update new Lead(
      Id = l.Id,
      SOL_Data_Inicio_Ciclo_Contato__c = System.now()
    );

    Test.startTest();
    tasksNegativas(l.Id, 2); // novo ciclo: só 2 -> não reatribui
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    System.assertEquals(1, recarregar(l.Id).SOL_Quantidade_Reatribuicoes__c);

    tasksNegativas(l.Id, 1); // fecha as 3 do novo ciclo -> reatribui de novo
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertEquals(2, recarregar(l.Id).SOL_Quantidade_Reatribuicoes__c);
  }

  // ============================================================ ESCOPO

  @IsTest
  static void leadDeOutraBUEhIgnorado() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSemRT('S6');
    Id ownerInicial = l.OwnerId;
    tasksNegativas(l.Id, 3);

    Test.startTest();
    SOLDistribuicaoService.ResultadoReatribuicao r = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidos);
    System.assert(r.ignorados >= 1);
    System.assertEquals(ownerInicial, recarregar(l.Id).OwnerId);
  }

  @IsTest
  static void leadConvertidoEhIgnorado() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S7');
    tasksNegativas(l.Id, 3);
    Lead aposTarefas = recarregar(l.Id);
    Id ownerAntesConversao = aposTarefas.OwnerId;

    update new Lead(Id = l.Id, SOL_Status_Procuracao__c = 'Recebida');

    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1]
      .MasterLabel
    );
    Database.convertLead(lc);

    Test.startTest();
    SOLDistribuicaoService.ResultadoReatribuicao r = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidos, 'Lead convertido não é reatribuído.');
    System.assertEquals(ownerAntesConversao, recarregar(l.Id).OwnerId);
  }

  @IsTest
  static void killSwitchDesativadoNaoReatribui() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S8');
    Id ownerInicial = l.OwnerId;
    killSwitch();

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(ownerInicial, d.OwnerId, 'Kill-switch off: sem troca.');
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c);
  }

  // ============================================================ ROTAÇÃO

  @IsTest
  static void proprietarioAtualEhExcluidoDaEscolha() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9'); // owner = vendedores[0]
    // Ponteiro em vendedores[2] => "próximo" seria vendedores[0] (o dono atual).
    ponteiro(c.vendedores[2]);

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      c.vendedores[1],
      d.OwnerId,
      'Pula o próprio dono atual e vai para o seguinte.'
    );
  }

  @IsTest
  static void vendedorAnteriorPermaneceNoRoster() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S10');
    Id anterior = l.OwnerId;

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertNotEquals(anterior, recarregar(l.Id).OwnerId);
    Integer aindaNaFila = [
      SELECT COUNT()
      FROM GroupMember
      WHERE GroupId = :c.filaId AND UserOrGroupId = :anterior
    ];
    System.assertEquals(1, aindaNaFila, 'O vendedor anterior continua no rodízio.');
  }

  @IsTest
  static void apenasUmVendedorMantemOLeadERegistraMotivo() {
    Cenario c = montarCenario(1);
    Lead l = novoLeadSOLDistribuido('S11'); // owner = vendedores[0], o único
    Id ownerInicial = l.OwnerId;
    Id ponteiroAntes = estado().Ultimo_Usuario__c;

    // Ciclo no futuro enquanto as tarefas são criadas (Flow não conta nada),
    // depois traz o ciclo para o passado e chama o serviço diretamente — assim
    // é a chamada explícita que executa o ramo "sem outro vendedor".
    update new Lead(
      Id = l.Id,
      SOL_Data_Inicio_Ciclo_Contato__c = System.now().addMinutes(30)
    );
    tasksNegativas(l.Id, 3);
    update new Lead(
      Id = l.Id,
      SOL_Data_Inicio_Ciclo_Contato__c = System.now().addMinutes(-10)
    );

    Test.startTest();
    SOLDistribuicaoService.ResultadoReatribuicao r = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(1, r.semOutroVendedor, 'Contabilizado como sem outro vendedor.');
    System.assertEquals(0, r.reatribuidos);

    Lead d = recarregar(l.Id);
    System.assertEquals(ownerInicial, d.OwnerId, 'Sem outro vendedor: mantém o Lead.');
    System.assertEquals('Sem outro vendedor', d.SOL_Status_Reatribuicao__c);
    System.assert(
      String.isNotBlank(d.SOL_Motivo_Ultima_Reatribuicao__c),
      'Registra o motivo.'
    );
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c, 'Não incrementa.');
    System.assertEquals(
      ponteiroAntes,
      estado().Ultimo_Usuario__c,
      'Ponteiro não avança.'
    );
    System.assertEquals(0, primeirasLigacoes(l.Id).size(), 'Sem tarefa duplicada.');
  }

  @IsTest
  static void usuarioInativoEhIgnoradoNaReatribuicao() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S12'); // owner = vendedores[0]
    System.runAs(contextoAtual()) {
      update new User(Id = c.vendedores[1], IsActive = false);
    }

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      c.vendedores[2],
      d.OwnerId,
      'Inativo (vendedores[1]) é pulado; vai para vendedores[2].'
    );
  }

  @IsTest
  static void membroIndiretoDaFilaEhIgnorado() {
    Cenario c = montarCenario(2);
    User viaGrupo = vendedor(99);
    System.runAs(contextoAtual()) {
      insert viaGrupo;
      Group aninhado = new Group(
        Name = 'RR Aninhado 9400',
        DeveloperName = 'RR_Aninhado_9400',
        Type = 'Regular'
      );
      insert aninhado;
      insert new GroupMember(GroupId = aninhado.Id, UserOrGroupId = viaGrupo.Id);
      insert new GroupMember(GroupId = c.filaId, UserOrGroupId = aninhado.Id);
    }
    Lead l = novoLeadSOLDistribuido('S13');

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assert(
      c.vendedores.contains(d.OwnerId),
      'Só membros diretos participam.'
    );
    System.assertNotEquals(
      viaGrupo.Id,
      d.OwnerId,
      'Usuário via grupo aninhado não recebe.'
    );
  }

  // ============================================================ BULK / CONCORRÊNCIA

  @IsTest
  static void processamentoBulk() {
    Cenario c = montarCenario(3);
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 20; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rtSOL(),
          LastName = 'Bulk ' + i,
          Company = 'C',
          Status = statusLead(),
          CNPJ__c = CNPJ
        )
      );
    }
    insert leads; // Flow distribui todos e abre os ciclos

    List<Task> ts = new List<Task>();
    for (Lead l : leads) {
      for (Integer k = 0; k < 3; k++) {
        ts.add(
          new Task(
            WhoId = l.Id,
            Subject = 'T',
            Status = 'Completed',
            ActivityDate = Date.today(),
            SOL_Resultado_Contato__c = 'Não atendeu'
          )
        );
      }
    }

    List<Id> ids = new List<Id>(new Map<Id, Lead>(leads).keySet());

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    insert ts; // um insert -> Flow agrupa -> Invocable 1x -> serviço 1x
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(ids);
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    for (Lead d : [
      SELECT SOL_Quantidade_Reatribuicoes__c
      FROM Lead
      WHERE Id IN :ids
    ]) {
      System.assertEquals(
        1,
        d.SOL_Quantidade_Reatribuicoes__c,
        'Cada Lead reatribuído exatamente uma vez.'
      );
    }
    System.assert(soql < 40, 'SOQL não escala por Lead/Task: ' + soql);
    System.assert(dml < 20, 'DML não escala por Lead/Task: ' + dml);
  }

  @IsTest
  static void duasTarefasSimultaneasNaoDuplicamAReatribuicao() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S14');

    tasksNegativas(l.Id, 1); // 1ª tentativa (Flow: 1 < 3, no-op)

    Test.startTest();
    // 2ª e 3ª concluídas no MESMO DML: Flow dispara uma vez em bulk.
    tasksNegativas(l.Id, 2);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      1,
      d.SOL_Quantidade_Reatribuicoes__c,
      'Uma única reatribuição, não duas.'
    );
    System.assertEquals(
      1,
      primeirasLigacoes(l.Id).size(),
      'Uma única tarefa 1ª Ligação.'
    );
  }

  @IsTest
  static void novaTarefaCriadaUmaUnicaVezParaNovoVendedor() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S15');

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    List<Task> pl = primeirasLigacoes(l.Id);
    System.assertEquals(1, pl.size(), 'Só uma tarefa 1ª Ligação mesmo com chamada repetida.');
    System.assertEquals(d.OwnerId, pl[0].OwnerId);
    System.assert(
      pl[0].Status != 'Completed',
      'A nova tarefa nasce aberta.'
    );
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
  }

  @IsTest
  static void historicoDeTarefasAnterioresPermanece() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S16');

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Integer negativas = [
      SELECT COUNT()
      FROM Task
      WHERE
        WhoId = :l.Id
        AND SOL_Resultado_Contato__c IN ('Não atendeu', 'Não foi possível ligar')
    ];
    System.assertEquals(3, negativas, 'As 3 tarefas do ciclo anterior continuam no histórico.');
    System.assertEquals(4, totalTasks(l.Id), '3 antigas + 1 nova (1ª Ligação).');
  }

  @IsTest
  static void roundRobinInicialContinuaFuncionando() {
    Cenario c = montarCenario(3);
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 3; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rtSOL(),
          LastName = 'RR ' + i,
          Company = 'C',
          Status = statusLead(),
          CNPJ__c = CNPJ
        )
      );
    }

    Test.startTest();
    insert leads;
    Test.stopTest();

    List<Lead> ds = [
      SELECT
        OwnerId,
        SOL_Status_Distribuicao__c,
        SOL_Status_Reatribuicao__c,
        SOL_Data_Inicio_Ciclo_Contato__c
      FROM Lead
      WHERE Id IN :leads
      ORDER BY CreatedDate ASC, Id ASC
    ];
    for (Integer i = 0; i < 3; i++) {
      System.assertEquals('Distribuido', ds[i].SOL_Status_Distribuicao__c);
      System.assertEquals(c.vendedores[i], ds[i].OwnerId, 'Rodízio inicial intacto.');
      System.assertEquals(
        'Em acompanhamento',
        ds[i].SOL_Status_Reatribuicao__c,
        'Distribuição inicial abre o ciclo de contato.'
      );
      System.assertNotEquals(null, ds[i].SOL_Data_Inicio_Ciclo_Contato__c);
    }
  }

  // ============================================================ CLICKUP-9396

  @IsTest
  static void resultadoNaoFoiPossivelLigarContaComoNegativo() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9396a');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    tasksResultado(l.Id, 3, 'Não foi possível ligar');
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(ownerInicial, d.OwnerId, '3x "Não foi possível ligar" reatribui.');
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
  }

  @IsTest
  static void combinacaoDeResultadosNegativosReatribui() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9396b');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    tasksResultado(l.Id, 1, 'Não atendeu');
    tasksResultado(l.Id, 2, 'Não foi possível ligar');
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(
      ownerInicial,
      d.OwnerId,
      '3 negativos combinados (1 "Não atendeu" + 2 "Não foi possível ligar") reatribuem.'
    );
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
  }

  @IsTest
  static void atendeuNoCicloBloqueiaMesmoComTresNegativos() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9396c');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    tasksResultado(l.Id, 2, 'Não atendeu');
    taskAtendeu(l.Id);
    tasksResultado(l.Id, 1, 'Não foi possível ligar'); // 3 negativos no total
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      ownerInicial,
      d.OwnerId,
      '"Atendeu" no ciclo bloqueia mesmo com 3 negativos.'
    );
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c);
  }

  @IsTest
  static void prazoDaLigacaoUsaHorarioComercial() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9396d');

    Test.startTest();
    tasksNegativas(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    List<Task> pl = primeirasLigacoes(l.Id);
    System.assertEquals(1, pl.size());
    Lead d = recarregar(l.Id);
    Datetime atribuicao = d.SOL_Data_Ultima_Reatribuicao__c;
    System.assertNotEquals(null, pl[0].SOL_Prazo_Contato__c);

    // (CLICKUP-9434) O calendário passou a ser resolvido pela fonte única
    // `SOLBusinessHoursHelper`; o wrapper duplicado do serviço foi removido.
    Id bhId = SOLBusinessHoursHelper.businessHoursId();
    System.assertNotEquals(
      null,
      bhId,
      'Business Hours "Arnone Soluções - Horário Comercial" é pré-requisito de implantação.'
    );
    // ~5 minutos ÚTEIS entre a atribuição e o prazo (BusinessHours.add
    // normaliza os segundos da origem, então a diferença fica ≈ 5 min).
    Long diffUtil = BusinessHours.diff(bhId, atribuicao, pl[0].SOL_Prazo_Contato__c);
    System.assert(
      diffUtil >= 210000L && diffUtil <= 300000L,
      'Prazo ≈ 5 minutos úteis (BusinessHours.diff = ' + diffUtil + ' ms).'
    );
    System.assert(
      BusinessHours.isWithin(bhId, pl[0].SOL_Prazo_Contato__c),
      'O prazo cai dentro do expediente.'
    );
    System.assert(pl[0].SOL_Prazo_Contato__c >= atribuicao, 'Nunca antes da atribuição.');
    // O prazo é EXATAMENTE o que BusinessHours.add produz para essa atribuição.
    System.assertEquals(
      BusinessHours.add(bhId, atribuicao, 5L * 60L * 1000L),
      pl[0].SOL_Prazo_Contato__c,
      'Prazo = BusinessHours.add(atribuição, 5 min).'
    );
  }

  @IsTest
  static void validationRuleExigeResultadoParaConcluirTask() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9396e');
    tasksNegativas(l.Id, 3); // Flow reatribui e cria a Task "1ª Ligação"

    Task ligacao = [
      SELECT Id, Status
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
      LIMIT 1
    ];

    Test.startTest();
    // Concluir SEM resultado -> bloqueado
    Boolean bloqueado = false;
    try {
      update new Task(Id = ligacao.Id, Status = 'Completed');
    } catch (DmlException e) {
      bloqueado = true;
      System.assert(
        e.getMessage().contains('Informe o resultado da ligação antes de concluir a tarefa'),
        'Mensagem da validação: ' + e.getMessage()
      );
    }
    System.assert(bloqueado, 'Concluir sem resultado deve ser bloqueado.');

    // Concluir COM resultado -> permitido
    update new Task(
      Id = ligacao.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
    Test.stopTest();

    System.assertEquals(
      'Completed',
      [SELECT Status FROM Task WHERE Id = :ligacao.Id].Status
    );
  }

  @IsTest
  static void tarefaVencidaPodeSerConcluida() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9396f');
    tasksNegativas(l.Id, 3);
    Task ligacao = [
      SELECT Id
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
      LIMIT 1
    ];

    Test.startTest();
    // "vence" a Task e ainda assim conclui com resultado
    update new Task(Id = ligacao.Id, ActivityDate = Date.today().addDays(-5));
    update new Task(
      Id = ligacao.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Não atendeu'
    );
    Test.stopTest();

    System.assertEquals(
      'Completed',
      [SELECT Status FROM Task WHERE Id = :ligacao.Id].Status,
      'Task vencida conclui normalmente (com resultado).'
    );
  }

  // ======================================================================
  //  CLICKUP-9437 — "Atendeu — sem conclusão"
  //
  //  O valor novo é o estado intermediário que faltava: houve conversa, mas
  //  nada avançou. Ele NÃO efetiva contato e CONTA como tentativa — a régua de
  //  três passa a somar três resultados, e só "Atendeu" continua bloqueando.
  //
  //  Todas as comparações usam o API NAME (ASCII), nunca o rótulo, porque é o
  //  API name que `TEXT()` devolve no filterFormula do Flow e o que o Apex
  //  compara.
  // ======================================================================

  private static final String RES_SEM_CONCLUSAO = 'Atendeu_Sem_Conclusao';

  /** (5) Três "Atendeu — sem conclusão" no ciclo reatribuem. */
  @IsTest
  static void tresAtendeuSemConclusaoReatribuem() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9437a');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    tasksResultado(l.Id, 3, RES_SEM_CONCLUSAO);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(
      ownerInicial,
      d.OwnerId,
      'Conversa sem avanço CONTA: três delas trocam o vendedor.'
    );
    System.assertEquals(c.vendedores[1], d.OwnerId, 'Próximo do rodízio.');
    System.assertEquals(
      1,
      d.SOL_Quantidade_Reatribuicoes__c,
      'Contador de reatribuições incrementado.'
    );
    System.assertEquals('Reatribuido', d.SOL_Status_Reatribuicao__c);
    System.assertEquals(
      'Sem contato após 3 tentativas',
      d.SOL_Motivo_Ultima_Reatribuicao__c
    );
    System.assertNotEquals(null, d.SOL_Data_Ultima_Reatribuicao__c);
    System.assertEquals(
      c.vendedores[1],
      estado().Ultimo_Usuario__c,
      'Ponteiro global avançou.'
    );

    List<Task> pl = primeirasLigacoes(l.Id);
    System.assertEquals(1, pl.size(), 'Uma "1ª Ligação" para o novo vendedor.');
    System.assertEquals(d.OwnerId, pl[0].OwnerId, 'Do novo proprietário.');
  }

  /** (6) Mistura dos três resultados contabilizáveis reatribui igualmente. */
  @IsTest
  static void misturaDosTresResultadosContabilizaveisReatribui() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9437b');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    tasksResultado(l.Id, 1, RES_SEM_CONCLUSAO);
    tasksResultado(l.Id, 1, 'Não atendeu');
    tasksResultado(l.Id, 1, 'Não foi possível ligar');
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(
      ownerInicial,
      d.OwnerId,
      'Os três contabilizáveis somam na MESMA régua.'
    );
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
    System.assertEquals('Reatribuido', d.SOL_Status_Reatribuicao__c);
  }

  /** (7) Duas ocorrências não bastam. */
  @IsTest
  static void duasOcorrenciasSemConclusaoNaoReatribuem() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9437c');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    tasksResultado(l.Id, 2, RES_SEM_CONCLUSAO);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(ownerInicial, d.OwnerId, 'Duas não trocam o vendedor.');
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c);
    System.assertEquals(
      'Em acompanhamento',
      d.SOL_Status_Reatribuicao__c,
      'O Lead segue com o mesmo vendedor, em acompanhamento.'
    );
  }

  /** (8) "Atendeu" no ciclo bloqueia, mesmo com três contabilizáveis. */
  @IsTest
  static void atendeuBloqueiaMesmoComTresSemConclusao() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9437d');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    taskAtendeu(l.Id);
    tasksResultado(l.Id, 3, RES_SEM_CONCLUSAO);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      ownerInicial,
      d.OwnerId,
      '"Atendeu" continua sendo o ÚNICO resultado que impede a troca.'
    );
    System.assertEquals(0, d.SOL_Quantidade_Reatribuicoes__c);
  }

  /**
   * (9) Reprocessar não reatribui duas vezes nem cria uma segunda "1ª Ligação".
   *
   * O que sustenta isso é o ciclo reiniciado para DEPOIS da última conclusão
   * contada: sem incluir "Atendeu_Sem_Conclusao" em RESULTADOS_CONSIDERADOS, as
   * tarefas que dispararam a troca ficariam fora desse cálculo, o ciclo novo
   * começaria antes delas e o mesmo Lead seria reatribuído em cascata.
   */
  @IsTest
  static void reprocessarSemConclusaoNaoReatribuiDuasVezes() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOLDistribuido('S9437e');

    Test.startTest();
    tasksResultado(l.Id, 3, RES_SEM_CONCLUSAO);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Lead aposPrimeira = recarregar(l.Id);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      aposPrimeira.OwnerId,
      d.OwnerId,
      'A segunda passagem não troca o vendedor de novo.'
    );
    System.assertEquals(
      1,
      d.SOL_Quantidade_Reatribuicoes__c,
      'Uma única reatribuição.'
    );
    System.assertEquals(
      1,
      primeirasLigacoes(l.Id).size(),
      'E uma única "1ª Ligação".'
    );

    Datetime ultimaContada = [
      SELECT CompletedDateTime
      FROM Task
      WHERE
        WhoId = :l.Id
        AND SOL_Resultado_Contato__c = :RES_SEM_CONCLUSAO
        AND IsClosed = TRUE
      ORDER BY CompletedDateTime DESC
      LIMIT 1
    ]
    .CompletedDateTime;
    System.assert(
      d.SOL_Data_Inicio_Ciclo_Contato__c > ultimaContada,
      'O ciclo novo começa DEPOIS da última conclusão contada — é o que impede a cascata. Ciclo=' +
        d.SOL_Data_Inicio_Ciclo_Contato__c +
        ' última=' +
        ultimaContada
    );
  }

  /** (10) Fora do escopo: outra BU, opt-out, negócio perdido e convertido. */
  @IsTest
  static void semConclusaoNaoAlcancaLeadsForaDoEscopo() {
    Cenario c = montarCenario(3);

    Lead outraBU = novoLeadSemRT('S9437f');
    Lead optOut = novoLeadSOLDistribuido('S9437g');
    Lead perdido = novoLeadSOLDistribuido('S9437h');
    Lead convertido = novoLeadSOLDistribuido('S9437i');

    for (Lead alvo : new List<Lead>{ outraBU, optOut, perdido, convertido }) {
      tasksResultado(alvo.Id, 3, RES_SEM_CONCLUSAO);
    }
    Map<Id, Id> donoAntes = new Map<Id, Id>();
    for (Lead alvo : new List<Lead>{ outraBU, optOut, perdido, convertido }) {
      donoAntes.put(alvo.Id, recarregar(alvo.Id).OwnerId);
    }

    update new Lead(
      Id = optOut.Id,
      SOL_Opt_Out__c = true,
      SOL_Motivo_Desqualificacao__c = 'Opt-out'
    );
    update new Lead(
      Id = perdido.Id,
      SOL_Produto_Interesse__c = 'Recuperação Tributária',
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = 'Negócio perdido'
    );
    update new Lead(Id = convertido.Id, SOL_Status_Procuracao__c = 'Recebida');
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(convertido.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1]
      .MasterLabel
    );
    Database.convertLead(lc);

    Test.startTest();
    SOLDistribuicaoService.ResultadoReatribuicao r = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      new List<Id>{ outraBU.Id, optOut.Id, perdido.Id, convertido.Id }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      r.reatribuidos,
      'Nenhum Lead fora do escopo é reatribuído pelo valor novo.'
    );
    System.assertEquals(4, r.ignorados, 'Os quatro são ignorados, sem erro.');
    System.assertEquals(0, r.comErro, 'Ignorar não é erro.');
    for (Id leadId : donoAntes.keySet()) {
      System.assertEquals(
        donoAntes.get(leadId),
        recarregar(leadId).OwnerId,
        'O proprietário não muda em Lead fora do escopo.'
      );
    }
  }
}
