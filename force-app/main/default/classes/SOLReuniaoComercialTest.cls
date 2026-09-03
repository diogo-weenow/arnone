/**
 * CLICKUP-9401 — Card 07A — Testes da criação automática da tarefa de reunião
 * comercial.
 *
 * O Flow SOL_Tarefa_Reuniao_Comercial está ATIVO: quando o Status do Lead SOL
 * muda para "Reunião Agendada - SQL" (Recuperação Tributária ou ART 360, não
 * convertido, sem opt-out), o Apex cria UMA Task "Realizar reunião comercial"
 * com vencimento 7 dias úteis. Os testes convivem com a automação real e também
 * chamam o serviço diretamente — a operação é idempotente.
 *
 * Inclui teste como VENDEDOR COM O PERMISSION SET COMERCIAL (PS_SOL_Comercial),
 * atomicidade da falha, calendário ausente e regressão dos Flows de reunião,
 * distribuição, contato efetivado e opt-out.
 */
@IsTest
private class SOLReuniaoComercialTest {
  private static final String FILA_SINTETICA = 'RR_Reuniao_SOL_9401';
  private static final String CNPJ = '11222333000181';
  private static final String STATUS_INICIAL = 'Captação - Contato';
  private static final String STATUS_SQL = 'Reunião Agendada - SQL';

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
      LastName = 'ReuniaoVend ' + i,
      Alias = ('rrn' + i).left(8),
      Email = 'rr.rn' + i + '@arnone.invalid',
      Username = 'rr.rn' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9401.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private class Cenario {
    List<Id> vendedores = new List<Id>();
  }

  private static Cenario montarCenario(Integer qtd) {
    Cenario c = new Cenario();
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      vs.add(vendedor(i));
    }
    System.runAs(contextoAtual()) {
      if (!vs.isEmpty()) {
        insert vs;
      }
      Group fila = new Group(
        Name = 'RR Reuniao SOL 9401',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
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

  private static Lead novoLeadSOL(String nome, String produto) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = nome,
      Company = 'C',
      Status = STATUS_INICIAL,
      CNPJ__c = CNPJ,
      SOL_Produto_Interesse__c = produto
    );
    insert l;
    return recarregar(l.Id);
  }

  private static Lead recarregar(Id id) {
    return [
      SELECT Id, OwnerId, Status, IsConverted, SOL_Opt_Out__c, SOL_Produto_Interesse__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  private static void promoverParaSQL(Id leadId) {
    update new Lead(Id = leadId, Status = STATUS_SQL);
  }

  private static List<Task> tarefasReuniao(Id leadId) {
    return [
      SELECT Id, Subject, Status, OwnerId, WhoId, ActivityDate, SOL_Tipo_Tarefa__c
      FROM Task
      WHERE WhoId = :leadId AND SOL_Tipo_Tarefa__c = 'Reunião comercial'
    ];
  }

  private static Task novaTarefaReuniao(Id leadId, Id owner, String status) {
    Task t = new Task(
      Subject = 'reunião pré-existente',
      WhoId = leadId,
      OwnerId = owner,
      Status = status,
      ActivityDate = Date.today().addDays(3),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;
    return t;
  }

  // ============================================================ POSITIVO

  @IsTest
  static void criaTarefaNaTransicaoParaSQL_RecuperacaoTributaria() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOL('S1', 'Recuperação Tributária');

    Datetime t0 = System.now();
    Test.startTest();
    promoverParaSQL(l.Id);
    Test.stopTest();

    List<Task> ts = tarefasReuniao(l.Id);
    System.assertEquals(1, ts.size(), 'Uma tarefa de reunião comercial.');
    System.assertEquals('Realizar reunião comercial', ts[0].Subject);
    System.assertEquals('Open', ts[0].Status);
    System.assertEquals(l.Id, ts[0].WhoId);
    System.assertEquals(l.OwnerId, ts[0].OwnerId, 'Proprietário da tarefa = dono do Lead.');
    System.assertEquals('Reunião comercial', ts[0].SOL_Tipo_Tarefa__c);
    System.assertEquals(
      esperado(bhIdReq(), t0, 7),
      ts[0].ActivityDate,
      '7 dias úteis (SP) após a mudança, pelo Business Hours.'
    );
    System.assert(
      dataSP(t0).daysBetween(ts[0].ActivityDate) >= 9,
      '7 dias úteis atravessam pelo menos um fim de semana: ' + ts[0].ActivityDate
    );
    // Não avança o Lead para "Procuração Solicitada".
    System.assertEquals(STATUS_SQL, recarregar(l.Id).Status);
  }

  @IsTest
  static void criaTarefa_ART360() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S2', 'ART 360');

    Test.startTest();
    promoverParaSQL(l.Id);
    Test.stopTest();

    System.assertEquals(1, tarefasReuniao(l.Id).size(), 'ART 360 funciona igual.');
  }

  @IsTest
  static void proprietarioDaTarefaAcompanhaODonoDoLead() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOL('S3', 'ART 360');
    // Reatribui o Lead a outro vendedor antes da transição.
    Id outro = c.vendedores[0] == l.OwnerId ? c.vendedores[1] : c.vendedores[0];
    update new Lead(Id = l.Id, OwnerId = outro);

    Test.startTest();
    promoverParaSQL(l.Id);
    Test.stopTest();

    List<Task> ts = tarefasReuniao(l.Id);
    System.assertEquals(1, ts.size());
    System.assertEquals(outro, ts[0].OwnerId, 'Tarefa vai para o dono ATUAL do Lead.');
  }

  // ============================================================ NÃO APLICA

  @IsTest
  static void atualizacaoSemMudancaDeStatusNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S4', 'Recuperação Tributária');
    promoverParaSQL(l.Id);
    System.assertEquals(1, tarefasReuniao(l.Id).size());

    Test.startTest();
    update new Lead(Id = l.Id, Description = 'edição qualquer, sem mexer no Status');
    Test.stopTest();

    System.assertEquals(1, tarefasReuniao(l.Id).size(), 'Sem transição de Status, nada muda.');
  }

  @IsTest
  static void outraBUNaoCria() {
    Cenario c = montarCenario(2);
    Lead outra = new Lead(LastName = 'OutraBU', Company = 'C'); // RT padrão, não SOL
    insert outra;

    Test.startTest();
    SOLReuniaoComercialService.ResultadoReuniaoComercial r = SOLReuniaoComercialService.criarTarefaReuniao(
      new List<Id>{ outra.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas, 'Lead de outra BU não gera tarefa SOL.');
    System.assert(r.ignorados >= 1);
    System.assertEquals(0, tarefasReuniao(outra.Id).size());
  }

  @IsTest
  static void produtoInvalidoNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S5', null); // produto em branco

    Test.startTest();
    promoverParaSQL(l.Id);
    Test.stopTest();

    System.assertEquals(0, tarefasReuniao(l.Id).size(), 'Produto fora de {Recuperação Tributária, ART 360}: sem tarefa.');
  }

  @IsTest
  static void leadConvertidoNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S6', 'Recuperação Tributária');
    // CLICKUP-9419: converter exige procuração Recebida com data + arquivo.
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    ContentVersion cv = new ContentVersion(
      Title = 'p9419',
      PathOnClient = 'p.txt',
      VersionData = Blob.valueOf('x')
    );
    insert cv;
    insert new ContentDocumentLink(
      ContentDocumentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]
        .ContentDocumentId,
      LinkedEntityId = l.Id,
      ShareType = 'V'
    );
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1].MasterLabel
    );
    Database.convertLead(lc);

    Test.startTest();
    SOLReuniaoComercialService.ResultadoReuniaoComercial r = SOLReuniaoComercialService.criarTarefaReuniao(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas);
    System.assert(r.ignorados >= 1);
    System.assertEquals(0, tarefasReuniao(l.Id).size());
  }

  @IsTest
  static void leadComOptOutNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S7', 'ART 360');
    update new Lead(Id = l.Id, SOL_Opt_Out__c = true);

    Test.startTest();
    promoverParaSQL(l.Id);
    SOLReuniaoComercialService.ResultadoReuniaoComercial r = SOLReuniaoComercialService.criarTarefaReuniao(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas, 'Lead em opt-out não recebe tarefa de reunião.');
    System.assertEquals(0, tarefasReuniao(l.Id).size());
  }

  // ============================================================ IDEMPOTÊNCIA

  @IsTest
  static void reprocessamentoNaoDuplica() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S8', 'Recuperação Tributária');

    Test.startTest();
    promoverParaSQL(l.Id);
    SOLReuniaoComercialService.ResultadoReuniaoComercial r2 = SOLReuniaoComercialService.criarTarefaReuniao(
      new List<Id>{ l.Id }
    );
    SOLReuniaoComercialService.ResultadoReuniaoComercial r3 = SOLReuniaoComercialService.criarTarefaReuniao(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r2.tarefasCriadas, '2ª chamada é no-op.');
    System.assertEquals(0, r3.tarefasCriadas, '3ª chamada é no-op.');
    System.assertEquals(1, tarefasReuniao(l.Id).size());
  }

  @IsTest
  static void reentradaNoStatusNaoDuplica() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S9', 'ART 360');
    promoverParaSQL(l.Id);
    System.assertEquals(1, tarefasReuniao(l.Id).size());

    Test.startTest();
    // Sai de SQL para uma etapa anterior (não gatilhada pelo CLICKUP-9419) e reentra.
    update new Lead(Id = l.Id, Status = 'Captação - Contato');
    update new Lead(Id = l.Id, Status = STATUS_SQL); // reentra em SQL
    Test.stopTest();

    System.assertEquals(1, tarefasReuniao(l.Id).size(), 'Reentrada em SQL não cria outra tarefa.');
  }

  @IsTest
  static void tarefaAbertaPreexistenteNaoDuplica() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S10', 'Recuperação Tributária');
    novaTarefaReuniao(l.Id, l.OwnerId, 'Open');

    Test.startTest();
    promoverParaSQL(l.Id);
    Test.stopTest();

    System.assertEquals(1, tarefasReuniao(l.Id).size(), 'Já existe uma tarefa aberta: não cria outra.');
  }

  @IsTest
  static void tarefaEncerradaPreexistenteNaoDuplica() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S11', 'ART 360');
    novaTarefaReuniao(l.Id, l.OwnerId, 'Completed');

    Test.startTest();
    promoverParaSQL(l.Id);
    Test.stopTest();

    List<Task> ts = tarefasReuniao(l.Id);
    System.assertEquals(1, ts.size(), 'Tarefa encerrada também conta: não recria.');
    System.assertEquals('Completed', ts[0].Status);
  }

  // ============================================================ BULK / CONCORRÊNCIA

  @IsTest
  static void processamentoBulk() {
    Cenario c = montarCenario(3);
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 12; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rtSOL(),
          LastName = 'Bulk ' + i,
          Company = 'C',
          Status = STATUS_INICIAL,
          CNPJ__c = CNPJ,
          SOL_Produto_Interesse__c = (Math.mod(i, 2) == 0 ? 'Recuperação Tributária' : 'ART 360')
        )
      );
    }
    insert leads;

    List<Lead> promo = new List<Lead>();
    for (Lead l : leads) {
      promo.add(new Lead(Id = l.Id, Status = STATUS_SQL));
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    update promo;
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(
      12,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhoId IN :leads AND SOL_Tipo_Tarefa__c = 'Reunião comercial'
      ]
    );
    System.assert(soql < 25, 'SOQL não escala por Lead: ' + soql);
    System.assert(dml < 12, 'DML não escala por Lead: ' + dml);
  }

  @IsTest
  static void duasChamadasNaMesmaTransacaoCriamUmaSo() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S12', 'ART 360');
    update new Lead(Id = l.Id, Status = STATUS_SQL);
    // primeira criação já ocorreu pelo Flow; simula corrida chamando de novo
    Test.startTest();
    SOLReuniaoComercialService.criarTarefaReuniao(new List<Id>{ l.Id });
    SOLReuniaoComercialService.criarTarefaReuniao(new List<Id>{ l.Id });
    Test.stopTest();
    System.assertEquals(1, tarefasReuniao(l.Id).size());
  }

  // ============================================================ PRAZO / CALENDÁRIO

  private static final String TZ_SP = 'America/Sao_Paulo';

  private static Id bhIdReq() {
    Id bhId = SOLReuniaoComercialService.businessHoursComercialId();
    System.assertNotEquals(
      null,
      bhId,
      'Business Hours "Arnone Soluções - Horário Comercial" é pré-requisito.'
    );
    return bhId;
  }

  /** Instante = HH:mm de São Paulo na data indicada (SP = GMT-3, sem verão). */
  private static Datetime spInstant(Integer y, Integer mo, Integer d, Integer h, Integer mi) {
    // 00:00 SP == 03:00 GMT do mesmo dia; soma minutos com rollover seguro.
    return Datetime.newInstanceGmt(y, mo, d, 0, 0, 0).addMinutes((h + 3) * 60 + mi);
  }

  private static Date dataSP(Datetime dt) {
    return Date.valueOf(dt.format('yyyy-MM-dd', TZ_SP));
  }

  /** Recontagem independente: N dias úteis após a DATA (SP) de `origem`. */
  private static Date esperado(Id bhId, Datetime origem, Integer n) {
    Date data = dataSP(origem);
    Integer contados = 0;
    Integer guarda = 0;
    while (contados < n && guarda < 400) {
      data = data.addDays(1);
      Datetime antes = Datetime.newInstanceGmt(data, Time.newInstance(0, 0, 0, 0));
      Datetime prox = BusinessHours.nextStartDate(bhId, antes);
      if (prox != null && dataSP(prox) == data) {
        contados++;
      }
      guarda++;
    }
    return data;
  }

  @IsTest
  static void prazoContaSextaMesmoComOrigemQuintaAs1730() {
    Id bhId = bhIdReq();
    // Quinta 2026-09-10, 17:30 SP (expediente da quinta vai até 18:00).
    Datetime origem = spInstant(2026, 9, 10, 17, 30);
    Datetime prazo = SOLReuniaoComercialService.prazoEmDiasUteis(bhId, origem, 7);

    // 09-11 é SEXTA (fecha 17:00) e DEVE contar como dia 1.
    // Dias úteis após 09-10: 11(1) 14(2) 15(3) 16(4) 17(5) 18(6) 21(7).
    System.assertEquals(
      Date.newInstance(2026, 9, 21),
      dataSP(prazo),
      'A sexta 09-11 conta como dia útil mesmo encerrando às 17h.'
    );
    System.assertEquals(Date.newInstance(2026, 9, 21), esperado(bhId, origem, 7));
  }

  @IsTest
  static void prazoComOrigemForaDoExpediente() {
    Id bhId = bhIdReq();
    // Quinta 2026-09-10, 22:00 SP — muito depois do fechamento.
    Datetime origem = spInstant(2026, 9, 10, 22, 0);
    Datetime prazo = SOLReuniaoComercialService.prazoEmDiasUteis(bhId, origem, 7);
    // A contagem começa no dia seguinte por DATA: 09-11 ainda é dia 1.
    System.assertEquals(Date.newInstance(2026, 9, 21), dataSP(prazo));
  }

  @IsTest
  static void prazoComOrigemNoFimDeSemana() {
    Id bhId = bhIdReq();
    // Sábado 2026-09-12, 10:00 SP.
    Datetime origem = spInstant(2026, 9, 12, 10, 0);
    Datetime prazo = SOLReuniaoComercialService.prazoEmDiasUteis(bhId, origem, 7);
    // Dias úteis após 09-12: 14(1) 15(2) 16(3) 17(4) 18(5) 21(6) 22(7).
    System.assertEquals(Date.newInstance(2026, 9, 22), dataSP(prazo));
    System.assertEquals(Date.newInstance(2026, 9, 22), esperado(bhId, origem, 7));
  }

  @IsTest
  static void activityDateConvertidaSemDeslocamentoDeTimezone() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('SPrazo', 'Recuperação Tributária');

    // Origem numa QUARTA => o 7º dia útil cai numa SEXTA (2026-09-11).
    Datetime origem = spInstant(2026, 9, 2, 12, 0);
    Id bhId = bhIdReq();
    Datetime prazo = SOLReuniaoComercialService.prazoEmDiasUteis(bhId, origem, 7);

    // prazo é a abertura (08:00 SP = 11:00 GMT); a data em SP é 09-11.
    System.assertEquals('2026-09-11', prazo.format('yyyy-MM-dd', TZ_SP));
    System.assertEquals(Date.newInstance(2026, 9, 11), dataSP(prazo));
    System.assertEquals(
      Date.newInstance(2026, 9, 11),
      SOLReuniaoComercialService.dataEm(prazo, TZ_SP),
      'Task.ActivityDate = data de São Paulo, sem deslocar por GMT.'
    );

    // E a tarefa real: ActivityDate = data (SP) do 7º dia útil a partir de agora.
    Datetime t0 = System.now();
    Test.startTest();
    promoverParaSQL(l.Id);
    Test.stopTest();

    List<Task> ts = tarefasReuniao(l.Id);
    System.assertEquals(1, ts.size());
    System.assertEquals(
      esperado(bhId, t0, 7),
      ts[0].ActivityDate,
      'ActivityDate = 7º dia útil (SP) contado a partir da mudança.'
    );
  }

  @IsTest
  static void prazoSeteDiasUteisRegressao() {
    Id bhId = bhIdReq();
    // Terça 2026-03-03, meio-dia SP.
    Datetime origem = spInstant(2026, 3, 3, 12, 0);
    Datetime prazo = SOLReuniaoComercialService.prazoEmDiasUteis(bhId, origem, 7);

    Date esperada = esperado(bhId, origem, 7);
    System.assertEquals(esperada, dataSP(prazo), '7 dias úteis pelo Business Hours.');

    // No intervalo (origem, prazo] há exatamente 7 dias úteis e pelo menos um
    // fim de semana pulado.
    Integer uteis = 0;
    Integer naoUteis = 0;
    Date d = dataSP(origem);
    while (d < esperada) {
      d = d.addDays(1);
      Datetime antes = Datetime.newInstanceGmt(d, Time.newInstance(0, 0, 0, 0));
      Datetime prox = BusinessHours.nextStartDate(bhId, antes);
      if (prox != null && dataSP(prox) == d) {
        uteis++;
      } else {
        naoUteis++;
      }
    }
    System.assertEquals(7, uteis, 'Exatamente 7 dias úteis entre a mudança e o prazo (inclusive).');
    System.assert(naoUteis >= 2, 'Pelo menos um fim de semana foi pulado (não úteis: ' + naoUteis + ').');
    System.assert(
      dataSP(origem).daysBetween(esperada) >= 9,
      '7 dias úteis = pelo menos 9 dias corridos.'
    );
    // A MESMA via (BusinessHours.nextStartDate) exclui feriados do calendário.
  }

  @IsTest
  static void calendarioAusenteAbortaComRollback() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S13', 'Recuperação Tributária');

    Test.startTest();
    SOLReuniaoComercialService.forcarBusinessHours(null); // calendário "ausente"
    Boolean lancou = false;
    try {
      promoverParaSQL(l.Id);
    } catch (Exception e) {
      lancou = true;
      System.assert(
        e.getMessage().contains('calendário'),
        'Mensagem controlada de calendário ausente: ' + e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(lancou, 'Calendário ausente aborta com exceção controlada.');
    System.assertEquals(0, tarefasReuniao(l.Id).size(), 'Nenhuma tarefa criada.');
    System.assertEquals(
      STATUS_INICIAL,
      recarregar(l.Id).Status,
      'A mudança de etapa foi desfeita (atômico).'
    );
  }

  @IsTest
  static void calendarioAusenteNaChamadaDiretaLanca() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S14', 'ART 360');
    update new Lead(Id = l.Id, Status = STATUS_SQL);
    // remove a tarefa criada pelo Flow para isolar a chamada direta
    delete tarefasReuniao(l.Id);

    Test.startTest();
    SOLReuniaoComercialService.forcarBusinessHours(null);
    Boolean lancou = false;
    try {
      SOLReuniaoComercialService.criarTarefaReuniao(new List<Id>{ l.Id });
    } catch (SOLReuniaoComercialService.ReuniaoComercialException e) {
      lancou = true;
    }
    Test.stopTest();

    System.assert(lancou);
    System.assertEquals(0, tarefasReuniao(l.Id).size());
  }

  // ============================================================ ATOMICIDADE

  @IsTest
  static void falhaNaCriacaoAbortaAtomicamente() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S15', 'ART 360');
    update new Lead(Id = l.Id, Status = STATUS_SQL);
    delete tarefasReuniao(l.Id);

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLReuniaoComercialService.criarTarefaReuniao(new List<Id>{ l.Id });
    } catch (SOLReuniaoComercialService.ReuniaoComercialException e) {
      lancou = true;
      System.assertEquals(SOLReuniaoComercialService.MSG_FALHA, e.getMessage());
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'Falha relança ReuniaoComercialException (não engole).');
    System.assertEquals(0, tarefasReuniao(l.Id).size(), 'Rollback: nenhuma tarefa.');
  }

  @IsTest
  static void invocableRelancaAFalha() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S16', 'ART 360');
    update new Lead(Id = l.Id, Status = STATUS_SQL);
    delete tarefasReuniao(l.Id);

    SOLReuniaoComercialInvocable.Entrada e = new SOLReuniaoComercialInvocable.Entrada();
    e.leadId = l.Id;

    Test.startTest();
    SOLReuniaoComercialService.forcarBusinessHours(null);
    Boolean lancou = false;
    try {
      SOLReuniaoComercialInvocable.criar(new List<SOLReuniaoComercialInvocable.Entrada>{ e });
    } catch (SOLReuniaoComercialService.ReuniaoComercialException ex) {
      lancou = true;
    }
    Test.stopTest();

    System.assert(lancou, 'O Invocable relança a falha para o Flow abortar a transação.');
  }

  @IsTest
  static void invocableIgnoraEntradasInvalidas() {
    Test.startTest();
    SOLReuniaoComercialInvocable.criar(null);
    SOLReuniaoComercialInvocable.criar(new List<SOLReuniaoComercialInvocable.Entrada>());
    SOLReuniaoComercialInvocable.Entrada semId = new SOLReuniaoComercialInvocable.Entrada();
    semId.leadId = null;
    SOLReuniaoComercialInvocable.criar(
      new List<SOLReuniaoComercialInvocable.Entrada>{ semId, null }
    );
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE SOL_Tipo_Tarefa__c = 'Reunião comercial']
    );
  }

  @IsTest
  static void colecaoVaziaOuNulaEhNoOp() {
    Test.startTest();
    SOLReuniaoComercialService.ResultadoReuniaoComercial r1 = SOLReuniaoComercialService.criarTarefaReuniao(null);
    SOLReuniaoComercialService.ResultadoReuniaoComercial r2 = SOLReuniaoComercialService.criarTarefaReuniao(new List<Id>());
    Test.stopTest();
    System.assertEquals(0, r1.tarefasCriadas);
    System.assertEquals(0, r2.tarefasCriadas);
  }

  // ============================================================ VENDEDOR COMERCIAL

  private static Id psSolComercialId() {
    return [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id;
  }

  private static Id profileStandardId() {
    Map<String, Id> porNome = new Map<String, Id>();
    for (Profile p : [SELECT Id, Name FROM Profile WHERE UserType = 'Standard']) {
      porNome.put(p.Name, p.Id);
    }
    if (porNome.containsKey('Standard User')) {
      return porNome.get('Standard User');
    }
    return porNome.isEmpty() ? UserInfo.getProfileId() : porNome.values()[0];
  }

  private static User vendedorComercial() {
    return new User(
      FirstName = 'RR',
      LastName = 'Comercial Reuniao',
      Alias = 'rrncom',
      Email = 'rr.rncom@arnone.invalid',
      Username = 'rr.rncom.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9401.test.invalid',
      ProfileId = profileStandardId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  @IsTest
  static void vendedorComercialDisparaFlowEApex() {
    User comercial = vendedorComercial();
    System.runAs(contextoAtual()) {
      insert comercial;
      insert new PermissionSetAssignment(
        AssigneeId = comercial.Id,
        PermissionSetId = psSolComercialId()
      );
      Group fila = new Group(
        Name = 'RR Reuniao Comercial 9401',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      insert new GroupMember(GroupId = fila.Id, UserOrGroupId = comercial.Id);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;

    Lead l = novoLeadSOL('SComercial', 'Recuperação Tributária');
    System.assertEquals(comercial.Id, l.OwnerId);

    Test.startTest();
    // Caminho real: o vendedor agenda a reunião (Event). O Flow
    // SOL_Reuniao_Agendada_SQL promove o Lead a SQL (contexto de sistema) e a
    // promoção dispara a criação da tarefa — sem o PS bloquear.
    System.runAs(new User(Id = comercial.Id)) {
      insert new Event(
        Subject = 'Reunião comercial',
        WhoId = l.Id,
        OwnerId = comercial.Id,
        StartDateTime = System.now().addDays(2),
        EndDateTime = System.now().addDays(2).addHours(1),
        SOL_Resultado_Reuniao__c = 'Agendada'
      );
    }
    Test.stopTest();

    System.assertEquals(STATUS_SQL, recarregar(l.Id).Status);
    List<Task> ts = tarefasReuniao(l.Id);
    System.assertEquals(1, ts.size(), 'Vendedor comercial dispara o Flow + Apex.');
    System.assertEquals(comercial.Id, ts[0].OwnerId);
    System.assertEquals('Reunião comercial', ts[0].SOL_Tipo_Tarefa__c);

    // FLS: vê o classificador (read-only) e edita o resultado da reunião.
    System.runAs(new User(Id = comercial.Id)) {
      Map<String, Schema.SObjectField> f = Schema.SObjectType.Task.fields.getMap();
      System.assert(
        f.get('SOL_Tipo_Tarefa__c').getDescribe().isAccessible(),
        'Vendedor enxerga SOL_Tipo_Tarefa__c.'
      );
      System.assert(
        !f.get('SOL_Tipo_Tarefa__c').getDescribe().isUpdateable(),
        'SOL_Tipo_Tarefa__c é somente leitura para o vendedor.'
      );
      System.assert(
        f.get('SOL_Resultado_Reuniao__c').getDescribe().isUpdateable(),
        'Vendedor edita SOL_Resultado_Reuniao__c.'
      );
    }
  }

  // ============================================================ REGRESSÃO

  @IsTest
  static void regressaoFlowReuniaoAgendadaSQLViaEvent() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('SReg1', 'Recuperação Tributária');

    Test.startTest();
    // O Flow SOL_Reuniao_Agendada_SQL (Event -> Lead SQL) continua promovendo,
    // e a promoção dispara a criação da tarefa de reunião.
    insert new Event(
      Subject = 'Reunião comercial agendada',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      StartDateTime = System.now().addDays(2),
      EndDateTime = System.now().addDays(2).addHours(1),
      SOL_Resultado_Reuniao__c = 'Agendada'
    );
    Test.stopTest();

    System.assertEquals(STATUS_SQL, recarregar(l.Id).Status, 'Event "Agendada" leva o Lead a SQL.');
    System.assertEquals(1, tarefasReuniao(l.Id).size(), 'A promoção via Event cria a tarefa de reunião.');
  }

  @IsTest
  static void regressaoDistribuicaoEContatoEfetivadoEOptOut() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOL('SReg2', 'ART 360');

    // Distribuição continua criando a "1ª Ligação".
    Integer ligacoes = [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
    ];
    System.assertEquals(1, ligacoes, 'Distribuição SOL intacta.');

    Test.startTest();
    // Contato efetivado continua cancelando a tarefa de contato.
    update new Task(
      Id = [SELECT Id FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação' LIMIT 1].Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
    Test.stopTest();

    System.assertEquals(
      true,
      [SELECT SOL_Contato_Efetivado__c FROM Lead WHERE Id = :l.Id].SOL_Contato_Efetivado__c,
      'Flow SOL_Contato_Efetivado intacto.'
    );

    // Opt-out continua desqualificando.
    Lead l2 = novoLeadSOL('SReg3', 'ART 360');
    Task contato = [
      SELECT Id FROM Task WHERE WhoId = :l2.Id AND Subject = '1ª Ligação' LIMIT 1
    ];
    update new Task(
      Id = contato.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Opt-out'
    );
    System.assertEquals(
      'Desqualificado',
      [SELECT Status FROM Lead WHERE Id = :l2.Id].Status,
      'Flow SOL_Opt_Out intacto.'
    );
  }
}
