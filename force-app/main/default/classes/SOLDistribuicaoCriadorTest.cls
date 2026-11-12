/**
 * SOL-LEAD-CRIADOR — Lead SOL criado manualmente por um vendedor fica com o
 * vendedor, sem round-robin.
 *
 * Regra (SOLDistribuicaoService.distribuir): o Lead elegível fica com o
 * criador quando (a) o criador é vendedor DIRETO e ATIVO da fila, (b) o criador
 * é o usuário da transação e (c) o canal é interativo. O canal é simulado pela
 * costura `quiddityOverride`; sem ela o teste roda em RUNTEST_*, que não é
 * interativo (é assim que os testes antigos continuam no rodízio).
 *
 * O Flow SOL_Distribuir_Lead está ATIVO: inserir o Lead dentro de
 * `System.runAs(vendedor)` reproduz o caminho real (tela -> Flow after-save ->
 * Invocable -> serviço), com `UserInfo.getUserId()` = criador.
 *
 * Os vendedores têm perfil Standard + PS_SOL_Comercial, como em produção, e a
 * fila é sintética (`queueDeveloperNameOverride`). O ponteiro começa no
 * vendedor v[0] (= A), então o rodízio entrega primeiro para v[1] (≠ A): um
 * Lead que "caiu no rodízio" nunca se confunde com um Lead mantido com A.
 */
@IsTest
private class SOLDistribuicaoCriadorTest {
  private static final String FILA_SINTETICA = 'RR_Criador_SOL';
  private static final String DOMINIO = '@arnone.solleadcriador.test.invalid';
  private static final String CNPJ = '11222333000181';
  private static final String ASSUNTO_LIGACAO = '1ª Ligação';
  private static final Decimal TOTAL_INICIAL = 5;
  private static final Datetime DATA_FIXA = Datetime.newInstanceGmt(
    2026,
    1,
    5,
    12,
    0,
    0
  );

  // ================================================================ setup

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');

    List<User> vendedores = new List<User>();
    for (Integer i = 0; i < 3; i++) {
      vendedores.add(usuario('vend' + i, perfilStandard()));
    }
    User admin = usuario('admin', UserInfo.getProfileId());
    User coord = usuario('coord', perfilStandard());

    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<User> todos = new List<User>(vendedores);
      todos.add(admin);
      todos.add(coord);
      insert todos;

      Id ps = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id;
      List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
      for (User u : vendedores) {
        psas.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps));
      }
      psas.add(new PermissionSetAssignment(AssigneeId = coord.Id, PermissionSetId = ps));
      insert psas;

      Group fila = new Group(
        Name = 'RR Criador SOL',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : vendedores) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = u.Id));
      }
      insert gms;
    }

    List<Id> ids = new List<Id>();
    for (User u : vendedores) {
      ids.add(u.Id);
    }
    ids.sort();
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
    e.Ativo__c = true;
    e.Ultimo_Usuario__c = ids[0];
    e.Total_Distribuido__c = TOTAL_INICIAL;
    e.Data_Ultima_Distribuicao__c = DATA_FIXA;
    e.Inicio_Vigencia__c = System.now().addDays(-1);
    update e;
  }

  // ================================================================ helpers

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

  private static User usuario(String tag, Id perfil) {
    return new User(
      FirstName = 'CRIADOR',
      LastName = tag,
      Alias = ('cr' + tag).left(8),
      Email = 'cr.' + tag + '@arnone.invalid',
      Username = 'cr.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        DOMINIO,
      ProfileId = perfil,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  /** Usuários do cenário e a fila; liga a costura da fila sintética. */
  private class Cenario {
    List<Id> v = new List<Id>(); // vendedores, User.Id ASC (ordem do rodízio)
    Id a; // vendedor A = v[0]
    Id b; // vendedor B = v[1]
    Id admin;
    Id coord;
    Id filaId;
  }

  private static Cenario cenario() {
    Cenario c = new Cenario();
    String dominio = '%' + DOMINIO;
    for (User u : [
      SELECT Id, LastName
      FROM User
      WHERE Username LIKE :dominio
      ORDER BY Id ASC
    ]) {
      if (u.LastName.startsWith('vend')) {
        c.v.add(u.Id);
      } else if (u.LastName == 'admin') {
        c.admin = u.Id;
      } else if (u.LastName == 'coord') {
        c.coord = u.Id;
      }
    }
    c.a = c.v[0];
    c.b = c.v[1];
    c.filaId = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = :FILA_SINTETICA
    ]
    .Id;
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    return c;
  }

  private static Id rt(String devName) {
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

  private static Lead montarLead(String tag, String rtDevName, Id ownerId) {
    Lead l = new Lead(
      RecordTypeId = rt(rtDevName),
      LastName = 'Criador ' + tag,
      Company = 'Empresa ' + tag,
      Status = statusLead(),
      CNPJ__c = CNPJ
    );
    if (ownerId != null) {
      l.OwnerId = ownerId;
    }
    return l;
  }

  /** Insere UM Lead SOL como `criador`, pelo canal `canal`. */
  private static Lead criarComo(Id criador, Quiddity canal, Id ownerId) {
    Lead l = montarLead('x' + Math.abs(Crypto.getRandomInteger()), 'SOL', ownerId);
    SOLDistribuicaoService.quiddityOverride = canal;
    System.runAs(new User(Id = criador)) {
      insert l;
    }
    return lead(l.Id);
  }

  private static Lead lead(Id id) {
    return [
      SELECT
        Id,
        OwnerId,
        CreatedById,
        RecordTypeId,
        SOL_Status_Distribuicao__c,
        SOL_Data_Distribuicao__c,
        SOL_Erro_Distribuicao__c,
        SOL_Data_Inicio_Ciclo_Contato__c,
        SOL_Status_Reatribuicao__c,
        SOL_Quantidade_Reatribuicoes__c,
        SOL_Data_Primeira_Ligacao__c,
        SOL_Dias_Primeira_Ligacao__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  private static List<Task> ligacoes(Id leadId) {
    return [
      SELECT Id, OwnerId, Status, WhoId
      FROM Task
      WHERE WhoId = :leadId AND Subject = :ASSUNTO_LIGACAO
    ];
  }

  private static SOL_Distribuicao_Estado__c estado() {
    return [
      SELECT Id, Ativo__c, Ultimo_Usuario__c, Total_Distribuido__c, Data_Ultima_Distribuicao__c
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
  }

  private static void ajustarAtivo(Boolean ativo) {
    SOL_Distribuicao_Estado__c e = estado();
    e.Ativo__c = ativo;
    update e;
  }

  private static void assertPonteiroIntacto(Cenario c, String contexto) {
    SOL_Distribuicao_Estado__c e = estado();
    Assert.areEqual(c.a, e.Ultimo_Usuario__c, contexto + ': Ultimo_Usuario__c não pode mudar.');
    Assert.areEqual(TOTAL_INICIAL, e.Total_Distribuido__c, contexto + ': Total_Distribuido__c não pode mudar.');
    Assert.areEqual(DATA_FIXA, e.Data_Ultima_Distribuicao__c, contexto + ': Data_Ultima_Distribuicao__c não pode mudar.');
  }

  private static void assertMantido(Lead l, Id donoEsperado, String contexto) {
    Assert.areEqual(donoEsperado, l.OwnerId, contexto + ': dono.');
    Assert.areEqual('Distribuido', l.SOL_Status_Distribuicao__c, contexto + ': mesmo status do rodízio.');
    Assert.isNotNull(l.SOL_Data_Distribuicao__c, contexto + ': data de distribuição.');
    Assert.isNotNull(l.SOL_Data_Inicio_Ciclo_Contato__c, contexto + ': início do ciclo.');
    Assert.isNull(l.SOL_Erro_Distribuicao__c, contexto + ': sem erro.');
    Assert.areEqual('Em acompanhamento', l.SOL_Status_Reatribuicao__c, contexto + ': acompanhamento 9400.');
    List<Task> t = ligacoes(l.Id);
    Assert.areEqual(1, t.size(), contexto + ': exatamente uma 1ª Ligação.');
    Assert.areEqual(donoEsperado, t[0].OwnerId, contexto + ': a 1ª Ligação é do dono.');
  }

  /** Rodízio a partir do ponteiro v[0]: o 1º Lead vai para v[1]. */
  private static void assertRodizio(Cenario c, Lead l, Id donoEsperado, String contexto) {
    Assert.areEqual(donoEsperado, l.OwnerId, contexto + ': dono pelo rodízio.');
    Assert.areEqual('Distribuido', l.SOL_Status_Distribuicao__c, contexto + ': status.');
    SOL_Distribuicao_Estado__c e = estado();
    Assert.areEqual(donoEsperado, e.Ultimo_Usuario__c, contexto + ': ponteiro avançou 1.');
    Assert.areEqual(TOTAL_INICIAL + 1, e.Total_Distribuido__c, contexto + ': total +1.');
    List<Task> t = ligacoes(l.Id);
    Assert.areEqual(1, t.size(), contexto + ': uma 1ª Ligação.');
    Assert.areEqual(donoEsperado, t[0].OwnerId, contexto + ': 1ª Ligação do vendedor do rodízio.');
  }

  // ======================================================= T01–T02 mantido

  @IsTest
  static void t01VendedorCriaPelaTelaFicaComEle() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.AURA, null);
    Test.stopTest();
    assertMantido(l, c.a, 'T01');
    assertPonteiroIntacto(c, 'T01');
  }

  @IsTest
  static void t02VendedorCriaViaRestFicaComEle() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.REST, null);
    Test.stopTest();
    assertMantido(l, c.a, 'T02');
    assertPonteiroIntacto(c, 'T02');
  }

  // ======================================== T03 canal não interativo -> rodízio

  @IsTest
  static void t03aBulkApiVaiParaORodizio() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.BULK_API, null);
    Test.stopTest();
    assertRodizio(c, l, c.b, 'T03 BULK_API');
  }

  @IsTest
  static void t03bBatchApexVaiParaORodizio() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.BATCH_APEX, null);
    Test.stopTest();
    assertRodizio(c, l, c.b, 'T03 BATCH_APEX');
  }

  @IsTest
  static void t03cAnonymousVaiParaORodizio() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.ANONYMOUS, null);
    Test.stopTest();
    assertRodizio(c, l, c.b, 'T03 ANONYMOUS');
  }

  // ================================================ T04–T06 criador não vendedor

  @IsTest
  static void t04AdminForaDaFilaVaiParaORodizio() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.admin, Quiddity.AURA, null);
    Test.stopTest();
    assertRodizio(c, l, c.b, 'T04');
  }

  @IsTest
  static void t05CoordenadorForaDaFilaVaiParaORodizio() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.coord, Quiddity.AURA, null);
    Test.stopTest();
    assertRodizio(c, l, c.b, 'T05');
  }

  @IsTest
  static void t06CriadorRemovidoDaFilaVaiParaORodizio() {
    Cenario c = cenario();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      delete [
        SELECT Id
        FROM GroupMember
        WHERE GroupId = :c.filaId AND UserOrGroupId = :c.a
      ];
    }
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.AURA, null);
    Test.stopTest();
    // Roster sem A = [v1, v2]; o ponteiro (A) não está no roster -> início 0 = v1.
    assertRodizio(c, l, c.b, 'T06');
  }

  // ===================================================== T07–T08 "em nome de"

  @IsTest
  static void t07aEmNomeDeOutroVendedorFicaComEle() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.AURA, c.b);
    Test.stopTest();
    assertMantido(l, c.b, 'T07a');
    Assert.areEqual(c.a, l.CreatedById, 'T07a: criado por A.');
    assertPonteiroIntacto(c, 'T07a');
  }

  @IsTest
  static void t07bEmNomeDeUsuarioForaDaListaFicaComOCriador() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.AURA, c.coord);
    Test.stopTest();
    assertMantido(l, c.a, 'T07b');
    assertPonteiroIntacto(c, 'T07b');
  }

  @IsTest
  static void t08DonoFilaFicaComOCriador() {
    Cenario c = cenario();
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.AURA, c.filaId);
    Test.stopTest();
    assertMantido(l, c.a, 'T08');
    assertPonteiroIntacto(c, 'T08');
  }

  // ============================================== T09–T10 troca de Record Type

  private static Lead leadSTECriadoPorA(Cenario c) {
    Lead l = montarLead('ste' + Math.abs(Crypto.getRandomInteger()), 'STE', null);
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    System.runAs(new User(Id = c.a)) {
      insert l;
    }
    return l;
  }

  @IsTest
  static void t09aCoordenadorMudaParaSOLVaiParaORodizio() {
    Cenario c = cenario();
    Lead l = leadSTECriadoPorA(c);
    // Em produção o coordenador enxerga o Lead do vendedor pela hierarquia de
    // papéis; aqui o acesso de edição é dado por compartilhamento manual.
    insert new LeadShare(
      LeadId = l.Id,
      UserOrGroupId = c.coord,
      LeadAccessLevel = 'Edit'
    );
    Test.startTest();
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    System.runAs(new User(Id = c.coord)) {
      update new Lead(Id = l.Id, RecordTypeId = rt('SOL'));
    }
    Test.stopTest();
    assertRodizio(c, lead(l.Id), c.b, 'T09a');
  }

  @IsTest
  static void t09bCriadorMudaParaSOLFicaComEle() {
    Cenario c = cenario();
    Lead l = leadSTECriadoPorA(c);
    Test.startTest();
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    System.runAs(new User(Id = c.a)) {
      update new Lead(Id = l.Id, RecordTypeId = rt('SOL'));
    }
    Test.stopTest();
    assertMantido(lead(l.Id), c.a, 'T09b');
    assertPonteiroIntacto(c, 'T09b');
  }

  @IsTest
  static void t10IdaEVoltaSOLSTESOLNaoRedistribui() {
    Cenario c = cenario();
    Lead l = criarComo(c.a, Quiddity.AURA, null);
    Datetime distribuidoEm = l.SOL_Data_Distribuicao__c;
    Test.startTest();
    System.runAs(new User(Id = c.a)) {
      update new Lead(Id = l.Id, RecordTypeId = rt('STE'));
      update new Lead(Id = l.Id, RecordTypeId = rt('SOL'));
    }
    Test.stopTest();
    Lead d = lead(l.Id);
    assertMantido(d, c.a, 'T10');
    Assert.areEqual(distribuidoEm, d.SOL_Data_Distribuicao__c, 'T10: a distribuição não foi refeita.');
    assertPonteiroIntacto(c, 'T10');
  }

  // =============================================================== T11 bulk

  @IsTest
  static void t11DuzentosPelaTelaFicamComOCriador() {
    Cenario c = cenario();
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 200; i++) {
      leads.add(montarLead('b' + i, 'SOL', null));
    }
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    Integer soql;
    Integer cpu;
    Test.startTest();
    System.runAs(new User(Id = c.a)) {
      insert leads;
    }
    soql = Limits.getQueries();
    cpu = Limits.getCpuTime();
    Test.stopTest();

    Set<Id> ids = new Map<Id, Lead>(leads).keySet();
    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Lead WHERE Id IN :ids AND OwnerId = :c.a AND SOL_Status_Distribuicao__c = 'Distribuido'],
      'T11: os 200 ficam com A, distribuídos.'
    );
    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Task WHERE WhoId IN :ids AND Subject = :ASSUNTO_LIGACAO AND OwnerId = :c.a],
      'T11: 200 Tasks 1ª Ligação de A.'
    );
    assertPonteiroIntacto(c, 'T11');
    Assert.isTrue(soql < Limits.getLimitQueries(), 'T11: SOQL dentro do limite: ' + soql);
    Assert.isTrue(cpu < Limits.getLimitCpuTime(), 'T11: CPU dentro do limite: ' + cpu);
    System.debug(LoggingLevel.INFO, 'T11 SOQL=' + soql + ' CPU=' + cpu);
  }

  // ============================================================== T12 misto

  @IsTest
  static void t12MistoViaServico() {
    Cenario c = cenario();
    // Kill-switch desligado na criação: os 200 nascem em Fallback (sem dono
    // vendedor, sem Task, ponteiro intocado) e ficam prontos para `distribuir`.
    ajustarAtivo(false);
    List<Lead> deA = new List<Lead>();
    List<Lead> doAdmin = new List<Lead>();
    for (Integer i = 0; i < 100; i++) {
      deA.add(montarLead('ma' + i, 'SOL', null));
      doAdmin.add(montarLead('md' + i, 'SOL', null));
    }
    System.runAs(new User(Id = c.a)) {
      insert deA;
    }
    System.runAs(new User(Id = c.admin)) {
      insert doAdmin;
    }
    ajustarAtivo(true);

    List<Id> todos = new List<Id>();
    for (Lead l : deA) {
      todos.add(l.Id);
    }
    for (Lead l : doAdmin) {
      todos.add(l.Id);
    }

    SOLDistribuicaoService.Resultado r;
    Test.startTest();
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    System.runAs(new User(Id = c.a)) {
      r = SOLDistribuicaoService.distribuir(todos);
    }
    Test.stopTest();

    Assert.areEqual(100, r.mantidosComCriador, 'T12: 100 mantidos.');
    Assert.areEqual(100, r.distribuidos, 'T12: 100 no rodízio.');
    Set<Id> idsA = new Map<Id, Lead>(deA).keySet();
    Assert.areEqual(
      100,
      [SELECT COUNT() FROM Lead WHERE Id IN :idsA AND OwnerId = :c.a AND SOL_Status_Distribuicao__c = 'Distribuido'],
      'T12: os 100 de A ficam com A.'
    );

    // Rodízio em sequência a partir do ponteiro (A = v0): v1, v2, v0, v1...
    Set<Id> idsAdm = new Map<Id, Lead>(doAdmin).keySet();
    Integer i = 0;
    for (Lead l : [
      SELECT Id, OwnerId, SOL_Status_Distribuicao__c
      FROM Lead
      WHERE Id IN :idsAdm
      ORDER BY CreatedDate ASC, Id ASC
    ]) {
      Assert.areEqual(c.v[Math.mod(1 + i, 3)], l.OwnerId, 'T12: sequência do rodízio no Lead ' + i);
      Assert.areEqual('Distribuido', l.SOL_Status_Distribuicao__c);
      i++;
    }
    Assert.areEqual(100, i);

    SOL_Distribuicao_Estado__c e = estado();
    Assert.areEqual(TOTAL_INICIAL + 100, e.Total_Distribuido__c, 'T12: total +100 (só o rodízio).');
    Assert.areEqual(c.v[Math.mod(1 + 99, 3)], e.Ultimo_Usuario__c, 'T12: ponteiro no último do rodízio.');

    Set<Id> todosSet = new Set<Id>(todos);
    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Task WHERE WhoId IN :todosSet AND Subject = :ASSUNTO_LIGACAO],
      'T12: 200 Tasks.'
    );
    Assert.areEqual(
      200,
      [SELECT WhoId FROM Task WHERE WhoId IN :todosSet AND Subject = :ASSUNTO_LIGACAO GROUP BY WhoId].size(),
      'T12: sem duplicata — uma por Lead.'
    );
  }

  // ======================================================== T13–T14 bordas

  @IsTest
  static void t13KillSwitchDesligadoVaiParaFilaSemTask() {
    Cenario c = cenario();
    ajustarAtivo(false);
    Test.startTest();
    Lead l = criarComo(c.a, Quiddity.AURA, null);
    Test.stopTest();
    Assert.areEqual(c.filaId, l.OwnerId, 'T13: fila como dona.');
    Assert.areEqual('Fallback', l.SOL_Status_Distribuicao__c, 'T13: Fallback.');
    Assert.areEqual(0, ligacoes(l.Id).size(), 'T13: sem Task.');
    SOL_Distribuicao_Estado__c e = estado();
    Assert.areEqual(c.a, e.Ultimo_Usuario__c);
    Assert.areEqual(TOTAL_INICIAL, e.Total_Distribuido__c);
  }

  @IsTest
  static void t14OptOutNaCriacaoEhIgnorado() {
    Cenario c = cenario();
    Lead l = montarLead('optout', 'SOL', null);
    l.SOL_Opt_Out__c = true;
    l.Status = 'Desqualificado';
    l.SOL_Motivo_Desqualificacao__c = 'Opt-out';
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    Test.startTest();
    System.runAs(new User(Id = c.a)) {
      insert l;
    }
    Test.stopTest();
    Lead d = lead(l.Id);
    Assert.isNull(d.SOL_Status_Distribuicao__c, 'T14: opt-out não é distribuído nem mantido.');
    Assert.areEqual(0, ligacoes(l.Id).size(), 'T14: sem Task.');
    assertPonteiroIntacto(c, 'T14');
  }

  // =============================================== T15–T16 reprocesso e erro

  @IsTest
  static void t15ReprocessamentoSoPegaOErro() {
    Cenario c = cenario();
    Lead mantido = criarComo(c.a, Quiddity.AURA, null);
    SOLDistribuicaoService.quiddityOverride = null;
    Lead comErro = criarComo(c.admin, null, null);
    update new Lead(
      Id = comErro.Id,
      OwnerId = c.filaId,
      SOL_Status_Distribuicao__c = 'Erro',
      SOL_Erro_Distribuicao__c = 'simulado'
    );
    delete [SELECT Id FROM Task WHERE WhoId = :comErro.Id];

    Test.startTest();
    Database.executeBatch(new SOLDistribuicaoReprocessamentoBatch(), 200);
    Test.stopTest();

    Lead m = lead(mantido.Id);
    Assert.areEqual(c.a, m.OwnerId, 'T15: mantido continua com A.');
    Assert.areEqual(mantido.SOL_Data_Distribuicao__c, m.SOL_Data_Distribuicao__c, 'T15: mantido não reprocessado.');
    Assert.areEqual(1, ligacoes(m.Id).size(), 'T15: mantido sem nova Task.');

    Lead e = lead(comErro.Id);
    Assert.areEqual('Distribuido', e.SOL_Status_Distribuicao__c, 'T15: o Erro foi reprocessado.');
    Assert.isTrue(c.v.contains(e.OwnerId), 'T15: Erro foi para um vendedor.');
    Assert.areEqual(1, ligacoes(e.Id).size(), 'T15: Erro recebeu a 1ª Ligação.');
  }

  @IsTest
  static void t16ErroForcadoNaoTocaOMantido() {
    Cenario c = cenario();
    Lead mantido = criarComo(c.a, Quiddity.AURA, null);
    ajustarAtivo(false);
    Lead pendente = criarComo(c.admin, null, null); // nasce em Fallback
    ajustarAtivo(true);

    SOLDistribuicaoService.Resultado r;
    Test.startTest();
    SOLDistribuicaoService.singletonKeyOverride = 'CHAVE_INEXISTENTE_CRIADOR';
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    System.runAs(new User(Id = c.a)) {
      r = SOLDistribuicaoService.distribuir(new List<Id>{ mantido.Id, pendente.Id });
    }
    SOLDistribuicaoService.singletonKeyOverride = null;
    Test.stopTest();

    Assert.areEqual(1, r.comErro, 'T16: só o pendente é marcado com erro.');
    Lead m = lead(mantido.Id);
    Assert.areEqual(c.a, m.OwnerId, 'T16: mantido segue com A.');
    Assert.areEqual('Distribuido', m.SOL_Status_Distribuicao__c, 'T16: status intacto.');
    Assert.isNull(m.SOL_Erro_Distribuicao__c, 'T16: sem mensagem de erro.');
    Assert.areEqual(mantido.SOL_Data_Distribuicao__c, m.SOL_Data_Distribuicao__c, 'T16: data intacta.');
    Assert.areEqual('Erro', lead(pendente.Id).SOL_Status_Distribuicao__c, 'T16: o erro aconteceu de fato.');
  }

  // ======================================================= T17–T18 jornada

  @IsTest
  static void t17ReatribuicaoAposTresTentativas() {
    Cenario c = cenario();
    Lead l = criarComo(c.a, Quiddity.AURA, null);
    List<Task> ts = new List<Task>();
    for (Integer i = 0; i < 3; i++) {
      ts.add(
        new Task(
          WhoId = l.Id,
          Subject = 'Tentativa de contato',
          Status = 'Completed',
          ActivityDate = Date.today(),
          SOL_Resultado_Contato__c = 'Não atendeu'
        )
      );
    }
    insert ts;

    Test.startTest();
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = lead(l.Id);
    Assert.areNotEqual(c.a, d.OwnerId, 'T17: saiu de A.');
    Assert.areEqual(c.b, d.OwnerId, 'T17: próximo do rodízio após o ponteiro.');
    Assert.areEqual(1, d.SOL_Quantidade_Reatribuicoes__c, 'T17: 1 reatribuição.');
    List<SOL_Evento_Jornada__c> ev = [
      SELECT SOL_Vendedor__c, SOL_Novo_Vendedor__c
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Lead__c = :l.Id
    ];
    Assert.areEqual(1, ev.size(), 'T17: um evento de jornada.');
    Assert.areEqual(c.a, ev[0].SOL_Vendedor__c, 'T17: vendedor anterior = A.');
    Assert.areEqual(c.b, ev[0].SOL_Novo_Vendedor__c, 'T17: novo vendedor.');
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = :ASSUNTO_LIGACAO AND OwnerId = :c.b],
      'T17: nova 1ª Ligação do novo vendedor.'
    );
  }

  @IsTest
  static void t18PrimeiraLigacaoConcluidaCalculaMarcoEDuracao() {
    Cenario c = cenario();
    Lead l = criarComo(c.a, Quiddity.AURA, null);
    Task t = ligacoes(l.Id)[0];
    Test.startTest();
    System.runAs(new User(Id = c.a)) {
      update new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Contato__c = 'Não atendeu');
    }
    Test.stopTest();
    Lead d = lead(l.Id);
    Assert.isNotNull(d.SOL_Data_Primeira_Ligacao__c, 'T18: marco da 1ª ligação.');
    Assert.isNotNull(d.SOL_Dias_Primeira_Ligacao__c, 'T18: duração da etapa 1.');
  }

  // ================================================================ T19 SOQL

  @IsTest
  static void t19SoqlDoMantidoNaoSuperaODoRodizio() {
    Cenario c = cenario();
    // Montados ANTES da medição: o cache de status/RecordType não entra na conta.
    Lead aquecimento = montarLead('q0', 'SOL', null);
    Lead mantido = montarLead('q1', 'SOL', null);
    Lead rodado = montarLead('q2', 'SOL', null);
    Test.startTest();
    // Aquecimento fora da medição: caches estáticos de outras automações
    // (horário comercial, unidade etc.) são carregados na 1ª inserção da
    // transação, e não podem pesar só contra o lote medido primeiro.
    SOLDistribuicaoService.quiddityOverride = Quiddity.BULK_API;
    System.runAs(new User(Id = c.a)) {
      insert aquecimento;
    }
    Integer q0 = Limits.getQueries();
    SOLDistribuicaoService.quiddityOverride = Quiddity.AURA;
    System.runAs(new User(Id = c.a)) {
      insert mantido;
    }
    Integer soqlMantido = Limits.getQueries() - q0;

    Integer q1 = Limits.getQueries();
    SOLDistribuicaoService.quiddityOverride = Quiddity.BULK_API;
    System.runAs(new User(Id = c.a)) {
      insert rodado;
    }
    Integer soqlRodizio = Limits.getQueries() - q1;
    Test.stopTest();

    Assert.areEqual(c.a, lead(mantido.Id).OwnerId, 'T19: pré-condição mantido.');
    Assert.isTrue(c.v.contains(lead(rodado.Id).OwnerId), 'T19: pré-condição rodízio.');
    Assert.areNotEqual(c.a, lead(rodado.Id).OwnerId, 'T19: o 2º do rodízio (após o aquecimento) vai para v2.');
    System.debug(LoggingLevel.INFO, 'T19 soqlMantido=' + soqlMantido + ' soqlRodizio=' + soqlRodizio);
    Assert.isTrue(
      soqlMantido <= soqlRodizio,
      'T19: lote mantido (' + soqlMantido + ') não pode gastar mais SOQL que o do rodízio (' + soqlRodizio + ').'
    );
  }
}
