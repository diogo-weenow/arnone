/**
 * CLICKUP-9394 — Testes do serviço de round-robin SOL.
 *
 * Fundação (ETAPA 3.1): localizar/validar a fila, membros diretos ativos,
 * bloqueio do singleton por Chave__c, unicidade.
 *
 * Serviço (ETAPA 4 / 5.1): rotação, ponteiro, fallback (kill-switch / roster
 * vazio), ignorar não-SOL e já distribuído, resultado controlado, erro de
 * configuração que deixa o Lead na fila.
 *
 * O Flow SOL_Distribuir_Lead está ATIVO — inserir um Lead SOL dispara a
 * distribuição real. Os testes que exercitam `distribuir()` diretamente
 * recriam o Lead num estado "ainda não distribuído" (helper `leadsSOLPristinos`)
 * em vez de desativar a automação. Nenhum teste depende de permission set: o
 * serviço roda em contexto de sistema.
 */
@IsTest
private class SOLDistribuicaoServiceTest {
  private static final String FILA_SINTETICA = 'RR_Svc_SOL_9394';
  private static final String CNPJ = '11222333000181';

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
      FirstName = 'RR',
      LastName = 'Teste ' + apelido,
      Alias = ('rr' + apelido).left(8),
      Email = 'rr.' + apelido + '@arnone.invalid',
      Username = 'rr.svc.' + unico + '@arnone.clickup9394.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static Id criarFilaSintetica(Boolean habilitarLead) {
    Group fila = new Group(
      Name = 'RR Svc SOL 9394',
      DeveloperName = FILA_SINTETICA,
      Type = 'Queue'
    );
    insert fila;
    if (habilitarLead) {
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
    }
    return fila.Id;
  }

  private class Cenario {
    Id filaId;
    List<Id> vendedores = new List<Id>();
  }

  private static Cenario montarCenario(Integer qtdVendedores) {
    Cenario c = new Cenario();
    List<User> criados = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      criados.add(montarUsuario('v' + i));
    }
    System.runAs(contextoAtual()) {
      if (!criados.isEmpty()) {
        insert criados;
      }
      c.filaId = criarFilaSintetica(true);
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : criados) {
        gms.add(new GroupMember(GroupId = c.filaId, UserOrGroupId = u.Id));
      }
      if (!gms.isEmpty()) {
        insert gms;
      }
    }
    for (User u : criados) {
      c.vendedores.add(u.Id);
    }
    c.vendedores.sort();
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

  private static void resetSingleton() {
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
    e.Ativo__c = true;
    e.Ultimo_Usuario__c = null;
    e.Total_Distribuido__c = 0;
    e.Data_Ultima_Distribuicao__c = null;
    update e;
  }

  /**
   * Cria N Leads SOL (o Flow ativo os distribui na inserção) e os devolve ao
   * estado "ainda não distribuído": status/data/erro nulos, owner = usuário do
   * teste, singleton zerado, e as Tasks "1ª Ligação" da distribuição inicial
   * removidas (para os testes contarem só o que a chamada explícita cria). O
   * update de reset não re-dispara o Flow (o RecordType não mudou).
   */
  private static List<Lead> leadsSOLPristinos(Integer qtd) {
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

    delete [
      SELECT Id
      FROM Task
      WHERE WhoId IN :leads AND Subject = '1ª Ligação'
    ];

    List<Lead> reset = new List<Lead>();
    for (Lead l : leads) {
      reset.add(
        new Lead(
          Id = l.Id,
          OwnerId = UserInfo.getUserId(),
          SOL_Status_Distribuicao__c = null,
          SOL_Data_Distribuicao__c = null,
          SOL_Erro_Distribuicao__c = null
        )
      );
    }
    update reset;
    resetSingleton();

    return [
      SELECT Id, OwnerId, SOL_Status_Distribuicao__c
      FROM Lead
      WHERE Id IN :leads
      ORDER BY CreatedDate ASC, Id ASC
    ];
  }

  private static List<Id> idsDe(List<Lead> leads) {
    List<Id> ids = new List<Id>();
    for (Lead l : leads) {
      ids.add(l.Id);
    }
    return ids;
  }

  private static Map<Id, Id> ownersDe(Set<Id> ids) {
    Map<Id, Id> m = new Map<Id, Id>();
    for (Lead l : [SELECT Id, OwnerId FROM Lead WHERE Id IN :ids]) {
      m.put(l.Id, l.OwnerId);
    }
    return m;
  }

  private static Map<Id, String> statusDe(Set<Id> ids) {
    Map<Id, String> m = new Map<Id, String>();
    for (Lead l : [
      SELECT Id, SOL_Status_Distribuicao__c
      FROM Lead
      WHERE Id IN :ids
    ]) {
      m.put(l.Id, l.SOL_Status_Distribuicao__c);
    }
    return m;
  }

  private static SOL_Distribuicao_Estado__c estado() {
    return [
      SELECT Ultimo_Usuario__c, Total_Distribuido__c, Data_Ultima_Distribuicao__c
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
  }

  private static void ajustarEstado(Id ultimoUsuario, Boolean ativo) {
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
    e.Ultimo_Usuario__c = ultimoUsuario;
    e.Ativo__c = ativo;
    update e;
  }

  // ============================================================ FUNDAÇÃO

  @IsTest
  static void localizaAFilaReal() {
    Test.startTest();
    Group fila = SOLDistribuicaoService.localizarFilaValida();
    Test.stopTest();
    System.assertEquals(
      SOLDistribuicaoService.QUEUE_DEVELOPER_NAME,
      fila.DeveloperName
    );
  }

  @IsTest
  static void rejeitaFilaInexistente() {
    SOLDistribuicaoService.queueDeveloperNameOverride = 'RR_Fila_Inexistente_9394';
    Test.startTest();
    try {
      SOLDistribuicaoService.localizarFilaValida();
      System.assert(false, 'Esperava FilaInexistenteException.');
    } catch (SOLDistribuicaoService.FilaInexistenteException e) {
      System.assert(String.isNotBlank(e.getMessage()));
    }
    Test.stopTest();
  }

  @IsTest
  static void rejeitaFilaNaoHabilitadaParaLead() {
    System.runAs(contextoAtual()) {
      criarFilaSintetica(false);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    Test.startTest();
    try {
      SOLDistribuicaoService.localizarFilaValida();
      System.assert(false, 'Esperava FilaInvalidaException.');
    } catch (SOLDistribuicaoService.FilaInvalidaException e) {
      System.assert(String.isNotBlank(e.getMessage()));
    }
    Test.stopTest();
  }

  @IsTest
  static void retornaSomenteMembrosDiretos() {
    User direto = montarUsuario('d1');
    User viaGrupo = montarUsuario('g1');
    System.runAs(contextoAtual()) {
      insert new List<User>{ direto, viaGrupo };
      Id filaId = criarFilaSintetica(true);
      Group aninhado = new Group(
        Name = 'RR Aninhado Svc',
        DeveloperName = 'RR_Aninhado_Svc',
        Type = 'Regular'
      );
      insert aninhado;
      insert new GroupMember(
        GroupId = aninhado.Id,
        UserOrGroupId = viaGrupo.Id
      );
      insert new List<GroupMember>{
        new GroupMember(GroupId = filaId, UserOrGroupId = direto.Id),
        new GroupMember(GroupId = filaId, UserOrGroupId = aninhado.Id)
      };
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;

    Test.startTest();
    List<User> membros = SOLDistribuicaoService.obterMembrosDiretosAtivos();
    Test.stopTest();

    System.assertEquals(1, membros.size());
    System.assertEquals(direto.Id, membros[0].Id);
  }

  @IsTest
  static void ignoraGruposEFilasAninhados() {
    User viaGrupo = montarUsuario('g2');
    System.runAs(contextoAtual()) {
      insert viaGrupo;
      Id filaId = criarFilaSintetica(true);
      Group aninhado = new Group(
        Name = 'RR Aninhado 2 Svc',
        DeveloperName = 'RR_Aninhado2_Svc',
        Type = 'Regular'
      );
      insert aninhado;
      insert new GroupMember(
        GroupId = aninhado.Id,
        UserOrGroupId = viaGrupo.Id
      );
      insert new GroupMember(GroupId = filaId, UserOrGroupId = aninhado.Id);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;

    Test.startTest();
    try {
      SOLDistribuicaoService.obterMembrosDiretosAtivos();
      System.assert(false, 'Esperava RosterVazioException.');
    } catch (SOLDistribuicaoService.RosterVazioException e) {
      System.assert(String.isNotBlank(e.getMessage()));
    }
    Test.stopTest();
  }

  @IsTest
  static void ignoraUsuariosInativosNoRoster() {
    User ativo = montarUsuario('a1');
    User inativo = montarUsuario('i1');
    System.runAs(contextoAtual()) {
      insert new List<User>{ ativo, inativo };
      inativo.IsActive = false;
      update inativo;
      Id filaId = criarFilaSintetica(true);
      insert new List<GroupMember>{
        new GroupMember(GroupId = filaId, UserOrGroupId = ativo.Id),
        new GroupMember(GroupId = filaId, UserOrGroupId = inativo.Id)
      };
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;

    Test.startTest();
    List<User> membros = SOLDistribuicaoService.obterMembrosDiretosAtivos();
    Test.stopTest();

    System.assertEquals(1, membros.size());
    System.assertEquals(ativo.Id, membros[0].Id);
  }

  @IsTest
  static void mantemOrdenacaoPorUserId() {
    List<User> us = new List<User>{
      montarUsuario('o1'),
      montarUsuario('o2'),
      montarUsuario('o3')
    };
    System.runAs(contextoAtual()) {
      insert us;
      Id filaId = criarFilaSintetica(true);
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : us) {
        gms.add(new GroupMember(GroupId = filaId, UserOrGroupId = u.Id));
      }
      insert gms;
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;

    Test.startTest();
    List<User> membros = SOLDistribuicaoService.obterMembrosDiretosAtivos();
    Test.stopTest();

    List<Id> esperado = new List<Id>{ us[0].Id, us[1].Id, us[2].Id };
    esperado.sort();
    List<Id> obtido = new List<Id>();
    for (User u : membros) {
      obtido.add(u.Id);
    }
    System.assertEquals(esperado, obtido);
  }

  @IsTest
  static void rosterVazioLancaExcecaoControlada() {
    System.runAs(contextoAtual()) {
      criarFilaSintetica(true);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    Test.startTest();
    try {
      SOLDistribuicaoService.obterMembrosDiretosAtivos();
      System.assert(false, 'Esperava RosterVazioException.');
    } catch (SOLDistribuicaoService.RosterVazioException e) {
      System.assert(String.isNotBlank(e.getMessage()));
    }
    Test.stopTest();
  }

  @IsTest
  static void filaSemLancarDevolveNullQuandoNaoExiste() {
    SOLDistribuicaoService.queueDeveloperNameOverride = 'RR_Nao_Existe_Svc';
    Test.startTest();
    Group g = SOLDistribuicaoService.filaSemLancar();
    Test.stopTest();
    System.assertEquals(null, g, 'Sem fila -> null, sem exceção.');
  }

  @IsTest
  static void bloqueiaERecuperaOSingletonPorChave() {
    Test.startTest();
    SOL_Distribuicao_Estado__c est = SOLDistribuicaoService.bloquearSingleton();
    Test.stopTest();
    System.assertNotEquals(null, est.Id);
    System.assertEquals('SOL', est.Chave__c);
    System.assertEquals(true, est.Ativo__c);
    System.assert(est.Total_Distribuido__c == 0);
  }

  @IsTest
  static void naoCriaSegundoRegistroComChaveSOL() {
    Test.startTest();
    Boolean bloqueou = false;
    try {
      insert new SOL_Distribuicao_Estado__c(Name = 'SOL duplicado');
    } catch (DmlException e) {
      bloqueou = true;
      System.assertEquals(StatusCode.DUPLICATE_VALUE, e.getDmlType(0));
    }
    Test.stopTest();
    System.assert(bloqueou);
  }

  @IsTest
  static void singletonAusenteLancaExcecaoControlada() {
    SOLDistribuicaoService.singletonKeyOverride = 'RR_CHAVE_INEXISTENTE_9394';
    Test.startTest();
    try {
      SOLDistribuicaoService.bloquearSingleton();
      System.assert(false, 'Esperava SingletonAusenteException.');
    } catch (SOLDistribuicaoService.SingletonAusenteException e) {
      System.assert(String.isNotBlank(e.getMessage()));
    }
    Test.stopTest();
  }

  // ============================================================ DISTRIBUIÇÃO

  @IsTest
  static void primeiroVendedorDaFila() {
    Cenario c = montarCenario(2);
    List<Lead> leads = leadsSOLPristinos(1);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Test.startTest();
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    Test.stopTest();

    System.assertEquals(1, r.distribuidos);
    System.assertEquals(c.vendedores[0], ownersDe(ids).get(leads[0].Id));
    SOL_Distribuicao_Estado__c est = estado();
    System.assertEquals(c.vendedores[0], est.Ultimo_Usuario__c);
    System.assert(est.Total_Distribuido__c == 1);
    // CLICKUP-9396: uma Task "1ª Ligação" para o vendedor que recebeu o Lead.
    List<Task> tks = [
      SELECT OwnerId, Status, SOL_Prazo_Contato__c, SOL_Resultado_Contato__c, ActivityDate
      FROM Task
      WHERE WhoId = :leads[0].Id AND Subject = '1ª Ligação'
    ];
    System.assertEquals(1, tks.size());
    System.assertEquals(c.vendedores[0], tks[0].OwnerId);
    System.assertEquals('Open', tks[0].Status);
    System.assertNotEquals(null, tks[0].SOL_Prazo_Contato__c);
    System.assertEquals(null, tks[0].SOL_Resultado_Contato__c);
    System.assertEquals(tks[0].SOL_Prazo_Contato__c.dateGmt(), tks[0].ActivityDate);
  }

  @IsTest
  static void sequenciaEntreVariosVendedoresELeads() {
    Cenario c = montarCenario(3);
    List<Lead> leads = leadsSOLPristinos(7);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Test.startTest();
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      idsDe(leads)
    );
    Test.stopTest();

    Map<Id, Id> owners = ownersDe(ids);
    System.assertEquals(7, r.distribuidos);
    for (Integer i = 0; i < leads.size(); i++) {
      System.assertEquals(
        c.vendedores[Math.mod(i, 3)],
        owners.get(leads[i].Id),
        'Lead ' + i
      );
    }
    System.assertEquals(c.vendedores[0], estado().Ultimo_Usuario__c);
    System.assert(estado().Total_Distribuido__c == 7);
  }

  @IsTest
  static void continuaAposOUltimoUsuario() {
    Cenario c = montarCenario(3);
    List<Lead> leads = leadsSOLPristinos(1);

    Test.startTest();
    ajustarEstado(c.vendedores[1], true);
    SOLDistribuicaoService.distribuir(idsDe(leads));
    Test.stopTest();

    System.assertEquals(
      c.vendedores[2],
      ownersDe(new Map<Id, Lead>(leads).keySet()).get(leads[0].Id)
    );
  }

  @IsTest
  static void voltaAoPrimeiroUsuario() {
    Cenario c = montarCenario(3);
    List<Lead> leads = leadsSOLPristinos(1);

    Test.startTest();
    ajustarEstado(c.vendedores[2], true);
    SOLDistribuicaoService.distribuir(idsDe(leads));
    Test.stopTest();

    System.assertEquals(
      c.vendedores[0],
      ownersDe(new Map<Id, Lead>(leads).keySet()).get(leads[0].Id)
    );
  }

  @IsTest
  static void ultimoUsuarioRemovidoDaFilaComecaDoPrimeiro() {
    Cenario c = montarCenario(3);
    User fantasma = montarUsuario('fan');
    List<Lead> leads = leadsSOLPristinos(1);

    Test.startTest();
    System.runAs(contextoAtual()) {
      insert fantasma;
    }
    ajustarEstado(fantasma.Id, true);
    SOLDistribuicaoService.distribuir(idsDe(leads));
    Test.stopTest();

    System.assertEquals(
      c.vendedores[0],
      ownersDe(new Map<Id, Lead>(leads).keySet()).get(leads[0].Id)
    );
  }

  @IsTest
  static void usuarioInativoIgnoradoNaDistribuicao() {
    Cenario c = montarCenario(2);
    List<Lead> leads = leadsSOLPristinos(3);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Test.startTest();
    System.runAs(contextoAtual()) {
      update new User(Id = c.vendedores[1], IsActive = false);
    }
    SOLDistribuicaoService.distribuir(new List<Id>(ids));
    Test.stopTest();

    for (Id owner : ownersDe(ids).values()) {
      System.assertEquals(c.vendedores[0], owner);
    }
  }

  @IsTest
  static void rosterVazioEnviaParaFilaComFallback() {
    Cenario c = montarCenario(0);
    List<Lead> leads = leadsSOLPristinos(2);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Test.startTest();
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    Test.stopTest();

    System.assertEquals(2, r.emFallback);
    System.assertEquals(0, r.distribuidos);
    for (Id owner : ownersDe(ids).values()) {
      System.assertEquals(c.filaId, owner);
    }
    for (String s : statusDe(ids).values()) {
      System.assertEquals('Fallback', s);
    }
    System.assertEquals(null, estado().Ultimo_Usuario__c);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId IN :ids AND Subject = '1ª Ligação'],
      'CLICKUP-9396: fallback não cria Task.'
    );
  }

  @IsTest
  static void killSwitchEnviaParaFilaComFallback() {
    Cenario c = montarCenario(2);
    List<Lead> leads = leadsSOLPristinos(2);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Test.startTest();
    ajustarEstado(null, false);
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    Test.stopTest();

    System.assertEquals(2, r.emFallback);
    for (Id owner : ownersDe(ids).values()) {
      System.assertEquals(c.filaId, owner);
    }
    for (String s : statusDe(ids).values()) {
      System.assertEquals('Fallback', s);
    }
    System.assertEquals(null, estado().Ultimo_Usuario__c);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId IN :ids AND Subject = '1ª Ligação'],
      'CLICKUP-9396: kill-switch/fallback não cria Task.'
    );
  }

  @IsTest
  static void leadSemRecordTypeSOLEhIgnorado() {
    Cenario c = montarCenario(2);
    List<Lead> sol = leadsSOLPristinos(1);
    Lead outro = new Lead(
      LastName = 'Sem RT',
      Company = 'C',
      Status = statusLead()
    ); // RecordTypeId nulo -> não é SOL
    insert outro;
    Set<Id> ids = new Set<Id>{ sol[0].Id, outro.Id };

    Test.startTest();
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    Test.stopTest();

    System.assertEquals(1, r.distribuidos);
    System.assert(r.ignorados >= 1);
    Map<Id, String> st = statusDe(ids);
    System.assertEquals('Distribuido', st.get(sol[0].Id));
    System.assertEquals(null, st.get(outro.Id), 'Não-SOL fica vazio.');
  }

  @IsTest
  static void leadJaDistribuidoNaoRedistribuido() {
    Cenario c = montarCenario(2);
    List<Lead> leads = leadsSOLPristinos(1);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Test.startTest();
    SOLDistribuicaoService.distribuir(new List<Id>(ids));
    Map<Id, Id> ownersApos1 = ownersDe(ids);
    Decimal totalApos1 = estado().Total_Distribuido__c;
    SOLDistribuicaoService.Resultado r2 = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    Test.stopTest();

    System.assertEquals(0, r2.distribuidos);
    System.assertEquals(1, r2.ignorados);
    System.assertEquals(ownersApos1.get(leads[0].Id), ownersDe(ids).get(leads[0].Id));
    System.assertEquals(totalApos1, estado().Total_Distribuido__c);
    // CLICKUP-9396: reexecução não duplica a Task "1ª Ligação".
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId IN :ids AND Subject = '1ª Ligação'],
      'Reprocessar um Lead já Distribuido não cria outra Task.'
    );
  }

  @IsTest
  static void bulkSemConsultaOuDmlEmLaco() {
    Cenario c = montarCenario(3);
    List<Lead> leads = leadsSOLPristinos(200);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Integer soql;
    Integer dml;
    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    soql = Limits.getQueries() - q0;
    dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(200, r.distribuidos);
    System.assert(soql <= 10, 'SOQL não escala por Lead: ' + soql);
    System.assert(dml <= 4, 'DML não escala por Lead: ' + dml);
    System.assert(estado().Total_Distribuido__c == 200);
    // CLICKUP-9396: exatamente uma Task "1ª Ligação" por Lead distribuído.
    System.assertEquals(
      200,
      [SELECT COUNT() FROM Task WHERE WhoId IN :ids AND Subject = '1ª Ligação'],
      'Uma Task "1ª Ligação" por Lead, mesmo em bulk.'
    );
  }

  @IsTest
  static void ponteiroETotalAtualizadosEntreExecucoes() {
    Cenario c = montarCenario(3);
    List<Lead> lote1 = leadsSOLPristinos(3);
    List<Lead> lote2 = leadsSOLPristinos(2);

    Test.startTest();
    SOLDistribuicaoService.distribuir(idsDe(lote1));
    SOL_Distribuicao_Estado__c est1 = estado();
    SOLDistribuicaoService.distribuir(idsDe(lote2));
    SOL_Distribuicao_Estado__c est2 = estado();
    Test.stopTest();

    System.assertEquals(c.vendedores[2], est1.Ultimo_Usuario__c);
    System.assert(est1.Total_Distribuido__c == 3);
    System.assertEquals(c.vendedores[1], est2.Ultimo_Usuario__c);
    System.assert(est2.Total_Distribuido__c == 5);
    System.assertNotEquals(null, est2.Data_Ultima_Distribuicao__c);
  }

  @IsTest
  static void singletonAusenteDeixaLeadNaFilaComErro() {
    Cenario c = montarCenario(2);
    List<Lead> leads = leadsSOLPristinos(2);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();

    Test.startTest();
    SOLDistribuicaoService.singletonKeyOverride = 'RR_INEXISTENTE_9394';
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    Test.stopTest();
    SOLDistribuicaoService.singletonKeyOverride = null;

    System.assertEquals(0, r.distribuidos);
    System.assertEquals(2, r.comErro);
    System.assert(r.mensagens.contains(SOLDistribuicaoService.MSG_CONFIG));
    for (String s : statusDe(ids).values()) {
      System.assertEquals('Erro', s);
    }
    // req 3: sem depender da Assignment Rule, o erro deixa o Lead na fila
    for (Id owner : ownersDe(ids).values()) {
      System.assertEquals(c.filaId, owner, 'Erro -> Lead fica na fila.');
    }
    System.assertEquals(null, estado().Ultimo_Usuario__c);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId IN :ids AND Subject = '1ª Ligação'],
      'CLICKUP-9396: erro não cria Task.'
    );
  }

  @IsTest
  static void erroSemFilaDisponivelSoRegistraCampos() {
    // singleton E fila indisponíveis: best-effort grava só status/data/mensagem
    List<Lead> leads = leadsSOLPristinos(1);
    Set<Id> ids = new Map<Id, Lead>(leads).keySet();
    Id ownerAntes = ownersDe(ids).get(leads[0].Id);

    Test.startTest();
    SOLDistribuicaoService.singletonKeyOverride = 'RR_INEXISTENTE_9394';
    SOLDistribuicaoService.queueDeveloperNameOverride = 'RR_FILA_INEXISTENTE_9394';
    SOLDistribuicaoService.Resultado r = SOLDistribuicaoService.distribuir(
      new List<Id>(ids)
    );
    Test.stopTest();
    SOLDistribuicaoService.singletonKeyOverride = null;
    SOLDistribuicaoService.queueDeveloperNameOverride = null;

    System.assertEquals(1, r.comErro);
    Map<Id, String> st = statusDe(ids);
    System.assertEquals('Erro', st.get(leads[0].Id));
    System.assertEquals(
      ownerAntes,
      ownersDe(ids).get(leads[0].Id),
      'Sem fila: owner não muda, sem nova exceção.'
    );
  }

  @IsTest
  static void colecaoVaziaOuNulaNaoFazNada() {
    Test.startTest();
    SOLDistribuicaoService.Resultado r1 = SOLDistribuicaoService.distribuir(
      new List<Id>()
    );
    SOLDistribuicaoService.Resultado r2 = SOLDistribuicaoService.distribuir(null);
    Test.stopTest();
    System.assertEquals(0, r1.distribuidos);
    System.assertEquals(0, r2.distribuidos);
  }
}