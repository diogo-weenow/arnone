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

  /** Insere um Lead SOL — o Flow ativo o distribui e abre o ciclo de contato. */
  private static Lead novoLeadSOLDistribuido(String nome) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = nome,
      Company = 'C',
      Status = statusLead(),
      CNPJ__c = CNPJ
    );
    insert l;
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

  private static void tasksSemSucesso(Id leadId, Integer qtd) {
    List<Task> ts = new List<Task>();
    for (Integer i = 0; i < qtd; i++) {
      ts.add(
        new Task(
          WhoId = leadId,
          Subject = 'Tentativa de contato',
          Status = 'Completed',
          ActivityDate = Date.today(),
          SOL_Resultado_Contato__c = 'Sem sucesso'
        )
      );
    }
    insert ts;
  }

  private static void taskSucesso(Id leadId) {
    insert new Task(
      WhoId = leadId,
      Subject = 'Contato efetivado',
      Status = 'Completed',
      ActivityDate = Date.today(),
      SOL_Resultado_Contato__c = 'Sucesso'
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
    tasksSemSucesso(l.Id, 2);
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
    tasksSemSucesso(l.Id, 3);
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
    taskSucesso(l.Id); // contato efetivado no ciclo
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3); // Flow dispara mas nada conta (antes do ciclo)
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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 2); // novo ciclo: só 2 -> não reatribui
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    System.assertEquals(1, recarregar(l.Id).SOL_Quantidade_Reatribuicoes__c);

    tasksSemSucesso(l.Id, 1); // fecha as 3 do novo ciclo -> reatribui de novo
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
    tasksSemSucesso(l.Id, 3);

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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3);
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
            SOL_Resultado_Contato__c = 'Sem sucesso'
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

    tasksSemSucesso(l.Id, 1); // 1ª tentativa (Flow: 1 < 3, no-op)

    Test.startTest();
    // 2ª e 3ª concluídas no MESMO DML: Flow dispara uma vez em bulk.
    tasksSemSucesso(l.Id, 2);
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
    tasksSemSucesso(l.Id, 3);
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
    tasksSemSucesso(l.Id, 3);
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Integer semSucesso = [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :l.Id AND SOL_Resultado_Contato__c = 'Sem sucesso'
    ];
    System.assertEquals(3, semSucesso, 'As 3 tarefas do ciclo anterior continuam no histórico.');
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
}
