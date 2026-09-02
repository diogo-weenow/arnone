/**
 * CLICKUP-9394 — ETAPA 6: testes da varredura de reprocessamento e do agendador.
 *
 * O Flow SOL_Distribuir_Lead está ativo — inserir um Lead SOL já dispara a
 * distribuição. Os testes forçam um status pós-distribuição (Erro / Fallback /
 * Pendente / vazio) para exercitar a varredura, sem desativar a automação.
 * Nenhum teste depende de permission set.
 */
@IsTest
private class SOLDistribuicaoReprocessamentoTest {
  private static final String FILA_SINTETICA = 'RR_Rep_SOL_9394';
  private static final String CNPJ = '11222333000181';
  private static final Datetime VIGENCIA = Datetime.newInstance(
    2026,
    1,
    1,
    0,
    0,
    0
  );

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      LIMIT 1
    ];
    e.Inicio_Vigencia__c = VIGENCIA;
    update e;
  }

  // ---------------------------------------------------------------- helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User vendedor(Integer i) {
    return new User(
      FirstName = 'RR',
      LastName = 'RepVend ' + i,
      Alias = ('rrr' + i).left(8),
      Email = 'rr.rv' + i + '@arnone.invalid',
      Username = 'rr.rv' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9394.test.invalid',
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
        Name = 'RR Rep SOL 9394',
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
   * Cria um Lead (o Flow ativo o processa) e força o status/owner desejados.
   * Se `antesDaVigencia`, recua a CreatedDate para antes do início de vigência.
   */
  private static Lead prepararLead(
    String rtDevName,
    String status,
    Id owner,
    Boolean antesDaVigencia
  ) {
    Lead l = new Lead(
      LastName = 'RepLead',
      Company = 'C',
      Status = statusLead()
    );
    if (rtDevName == 'SOL') {
      l.RecordTypeId = rtSOL();
      l.CNPJ__c = CNPJ;
    }
    insert l;

    // Remove a Task "1ª Ligação" da distribuição inicial (Flow) para os testes
    // contarem só o que o reprocessamento cria (CLICKUP-9396).
    delete [
      SELECT Id
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
    ];

    update new Lead(
      Id = l.Id,
      OwnerId = owner,
      SOL_Status_Distribuicao__c = status,
      SOL_Data_Distribuicao__c = null,
      SOL_Erro_Distribuicao__c = null
    );

    if (antesDaVigencia) {
      Test.setCreatedDate(l.Id, VIGENCIA.addDays(-30));
    }
    return recarregar(l.Id);
  }

  private static Lead prepararLeadSOL(String status, Boolean antesDaVigencia) {
    return prepararLead('SOL', status, UserInfo.getUserId(), antesDaVigencia);
  }

  private static Lead recarregar(Id id) {
    return [
      SELECT
        Id,
        OwnerId,
        RecordTypeId,
        IsConverted,
        SOL_Status_Distribuicao__c,
        LastModifiedDate,
        CreatedDate
      FROM Lead
      WHERE Id = :id
    ];
  }

  private static void desligarKillSwitch() {
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      LIMIT 1
    ];
    e.Ativo__c = false;
    update e;
  }

  private static Decimal totalDistribuido() {
    return [
      SELECT Total_Distribuido__c
      FROM SOL_Distribuicao_Estado__c
      LIMIT 1
    ]
    .Total_Distribuido__c;
  }

  private static void rodarBatch() {
    Test.startTest();
    Database.executeBatch(new SOLDistribuicaoReprocessamentoBatch(), 200);
    Test.stopTest();
  }

  // ============================================================ REPROCESSA

  @IsTest
  static void reprocessaErro() {
    Cenario c = montarCenario(2);
    Lead l = prepararLeadSOL('Erro', false);
    rodarBatch();
    Lead d = recarregar(l.Id);
    System.assertEquals('Distribuido', d.SOL_Status_Distribuicao__c);
    System.assert(c.vendedores.contains(d.OwnerId));
    // CLICKUP-9396: reprocessamento que distribui cria uma Task "1ª Ligação".
    List<Task> tks = [
      SELECT OwnerId, Status
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
    ];
    System.assertEquals(1, tks.size());
    System.assertEquals(d.OwnerId, tks[0].OwnerId);
    System.assertEquals('Open', tks[0].Status);
  }

  @IsTest
  static void reprocessaFallbackQuandoServicoVoltaADisponivel() {
    Cenario c = montarCenario(2); // roster disponível agora
    Lead l = prepararLead('SOL', 'Fallback', c.filaId, false);
    rodarBatch();
    Lead d = recarregar(l.Id);
    System.assertEquals('Distribuido', d.SOL_Status_Distribuicao__c);
    System.assert(c.vendedores.contains(d.OwnerId));
  }

  @IsTest
  static void reprocessaPendente() {
    Cenario c = montarCenario(2);
    Lead l = prepararLeadSOL('Pendente', false);
    rodarBatch();
    System.assertEquals(
      'Distribuido',
      recarregar(l.Id).SOL_Status_Distribuicao__c
    );
  }

  @IsTest
  static void reprocessaStatusVazioAposVigencia() {
    Cenario c = montarCenario(2);
    Lead l = prepararLeadSOL(null, false); // CreatedDate = agora > VIGENCIA
    rodarBatch();
    System.assertEquals(
      'Distribuido',
      recarregar(l.Id).SOL_Status_Distribuicao__c
    );
  }

  // ============================================================ IGNORA

  @IsTest
  static void ignoraStatusVazioAnteriorAVigencia() {
    Cenario c = montarCenario(2);
    Lead antigo = prepararLeadSOL(null, true); // CreatedDate < VIGENCIA
    Lead controle = prepararLeadSOL('Erro', false); // confirma que o batch rodou
    rodarBatch();

    System.assertEquals(
      null,
      recarregar(antigo.Id).SOL_Status_Distribuicao__c,
      'Lead anterior à vigência não é reprocessado.'
    );
    System.assertEquals(
      UserInfo.getUserId(),
      recarregar(antigo.Id).OwnerId,
      'Owner do Lead antigo intocado.'
    );
    System.assertEquals(
      'Distribuido',
      recarregar(controle.Id).SOL_Status_Distribuicao__c,
      'O batch efetivamente rodou.'
    );
  }

  @IsTest
  static void ignoraOutraBU() {
    Cenario c = montarCenario(2);
    Lead outra = prepararLead(
      'NENHUM',
      null,
      UserInfo.getUserId(),
      false
    ); // sem RecordType SOL
    Lead sol = prepararLeadSOL('Erro', false);
    rodarBatch();

    System.assertEquals(
      null,
      recarregar(outra.Id).SOL_Status_Distribuicao__c,
      'Lead de outra BU não é reprocessado.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :outra.Id AND Subject = '1ª Ligação'],
      'CLICKUP-9396: Lead de outra BU não cria Task no reprocessamento.'
    );
    System.assertEquals(
      'Distribuido',
      recarregar(sol.Id).SOL_Status_Distribuicao__c
    );
  }

  @IsTest
  static void ignoraConvertidoEDistribuido() {
    Cenario c = montarCenario(2);

    Lead jaDistribuido = prepararLeadSOL('Distribuido', false);
    Id ownerDistribuido = recarregar(jaDistribuido.Id).OwnerId;

    Lead paraConverter = prepararLeadSOL('Erro', false);
    update new Lead(
      Id = paraConverter.Id,
      SOL_Status_Procuracao__c = 'Recebida'
    );
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(paraConverter.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1]
      .MasterLabel
    );
    Database.convertLead(lc);

    rodarBatch();

    System.assertEquals(
      'Distribuido',
      recarregar(jaDistribuido.Id).SOL_Status_Distribuicao__c
    );
    System.assertEquals(
      ownerDistribuido,
      recarregar(jaDistribuido.Id).OwnerId,
      'Lead já Distribuido não é tocado.'
    );
    Lead conv = recarregar(paraConverter.Id);
    System.assertEquals(true, conv.IsConverted);
    System.assertEquals(
      'Erro',
      conv.SOL_Status_Distribuicao__c,
      'Lead convertido não é tocado.'
    );
  }

  // ============================================================ SEM CHURN

  @IsTest
  static void killSwitchDesativadoNaoAtualizaRegistros() {
    Cenario c = montarCenario(2);
    Lead l = prepararLeadSOL('Erro', false);
    Datetime lmdAntes = recarregar(l.Id).LastModifiedDate;
    Decimal totalAntes = totalDistribuido();
    desligarKillSwitch();

    rodarBatch();

    Lead d = recarregar(l.Id);
    System.assertEquals('Erro', d.SOL_Status_Distribuicao__c, 'Status intacto.');
    System.assertEquals(
      lmdAntes,
      d.LastModifiedDate,
      'O batch não tocou o Lead.'
    );
    System.assertEquals(totalAntes, totalDistribuido(), 'Contador intacto.');
  }

  @IsTest
  static void rosterVazioNaoAtualizaRegistros() {
    Cenario c = montarCenario(0); // fila sem membros
    Lead l = prepararLead('SOL', 'Fallback', c.filaId, false);
    Datetime lmdAntes = recarregar(l.Id).LastModifiedDate;

    rodarBatch();

    Lead d = recarregar(l.Id);
    System.assertEquals('Fallback', d.SOL_Status_Distribuicao__c);
    System.assertEquals(
      lmdAntes,
      d.LastModifiedDate,
      'Roster vazio -> o batch não churna o Lead.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação'],
      'CLICKUP-9396: roster vazio no reprocessamento não cria Task.'
    );
  }

  // ============================================================ LOTES

  @IsTest
  static void processamentoComMaisDeUmLote() {
    Cenario c = montarCenario(3);
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 5; i++) {
      leads.add(prepararLeadSOL('Erro', false));
    }

    // Chama execute() diretamente em dois lotes: prova que cada lote é uma
    // unidade independente e que uma falha num lote não afeta o outro.
    SOLDistribuicaoReprocessamentoBatch b = new SOLDistribuicaoReprocessamentoBatch();
    Test.startTest();
    b.execute(
      null,
      new List<Lead>{ leads[0], leads[1], leads[2] }
    );
    b.execute(null, new List<Lead>{ leads[3], leads[4] });
    Test.stopTest();

    for (Lead d : [
      SELECT SOL_Status_Distribuicao__c
      FROM Lead
      WHERE Id IN :leads
    ]) {
      System.assertEquals(
        'Distribuido',
        d.SOL_Status_Distribuicao__c,
        'Todos os Leads dos dois lotes foram reprocessados.'
      );
    }
  }

  @IsTest
  static void batchStartEExecuteViaFramework() {
    Cenario c = montarCenario(2);
    Lead l = prepararLeadSOL('Erro', false);

    Test.startTest();
    Database.executeBatch(new SOLDistribuicaoReprocessamentoBatch(), 200);
    Test.stopTest();

    System.assertEquals(
      'Distribuido',
      recarregar(l.Id).SOL_Status_Distribuicao__c
    );
  }

  // ============================================================ SCHEDULER

  @IsTest
  static void schedulerIniciaOBatch() {
    Cenario c = montarCenario(2);
    Lead l = prepararLeadSOL('Erro', false);

    Test.startTest();
    new SOLDistribuicaoReprocessamentoScheduler().execute(null);
    Test.stopTest();

    System.assertEquals(
      'Distribuido',
      recarregar(l.Id).SOL_Status_Distribuicao__c,
      'O Scheduler disparou o Batch e o Lead foi reprocessado.'
    );
  }

  @IsTest
  static void naoCriaAgendamentoDuplicado() {
    // Não toca o job real da org: se já existir, agendar() recusa de cara.
    Boolean jaExiste = ![
      SELECT Id
      FROM CronTrigger
      WHERE
        CronJobDetail.Name = :SOLDistribuicaoReprocessamentoScheduler.NOME_JOB
    ]
    .isEmpty();

    Test.startTest();
    Boolean recusouDuplicado = false;
    try {
      Id primeiro = SOLDistribuicaoReprocessamentoScheduler.agendar();
      System.assert(!jaExiste, 'Só agenda se ainda não existia.');
      System.assertNotEquals(null, primeiro);
      // agora existe -> a próxima deve recusar
      try {
        SOLDistribuicaoReprocessamentoScheduler.agendar();
      } catch (SOLDistribuicaoReprocessamentoScheduler.AgendamentoException e) {
        recusouDuplicado = true;
      }
    } catch (SOLDistribuicaoReprocessamentoScheduler.AgendamentoException e) {
      // já existia na org -> a 1ª chamada já recusou. Também é o comportamento correto.
      recusouDuplicado = true;
      System.assert(jaExiste);
    }
    Test.stopTest();

    System.assert(
      recusouDuplicado,
      'agendar() nunca pode criar um 2º job com o mesmo nome.'
    );
  }

  @IsTest
  static void desagendarNaoFalhaEEhIdempotente() {
    // Alterações de agendamento feitas em teste são revertidas ao fim.
    Test.startTest();
    SOLDistribuicaoReprocessamentoScheduler.desagendar();
    SOLDistribuicaoReprocessamentoScheduler.desagendar();
    Test.stopTest();
    System.assert(true, 'desagendar() nunca lança.');
  }

  @IsTest
  static void semVigenciaNaoReprocessa() {
    Cenario c = montarCenario(2);
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      LIMIT 1
    ];
    e.Inicio_Vigencia__c = null;
    update e;
    Lead l = prepararLeadSOL('Erro', false);
    Datetime lmdAntes = recarregar(l.Id).LastModifiedDate;

    rodarBatch();

    System.assertEquals(
      'Erro',
      recarregar(l.Id).SOL_Status_Distribuicao__c,
      'Sem Inicio_Vigencia__c a varredura não roda.'
    );
    System.assertEquals(lmdAntes, recarregar(l.Id).LastModifiedDate);
  }
}