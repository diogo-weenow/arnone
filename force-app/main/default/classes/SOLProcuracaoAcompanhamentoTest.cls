/**
 * CLICKUP-9426 — Card 07B — Testes da criação automática da tarefa de
 * acompanhamento da procuração.
 *
 * O Flow SOL_Tarefa_Acompanhamento_Procuracao está ATIVO: quando um Lead SOL
 * registra a solicitação da procuração (Status = "Procuração Solicitada" +
 * SOL_Status_Procuracao__c = "Solicitada" + SOL_Data_Solicitacao_Procuracao__c
 * preenchida), o Apex cria UMA Task "Acompanhar recebimento da procuração" com
 * vencimento 7 dias úteis. Os testes registram a solicitação com as MESMAS
 * gravações que o screen flow SOL_Procuracao faz no Lead (Status + campo de
 * status + data), sem invocá-lo.
 *
 * Vale para Recuperação Tributária E ART 360. Inclui teste como VENDEDOR COM O
 * PERMISSION SET COMERCIAL, atomicidade da falha, identidade da solicitação
 * (reprocessamento / reentrada / nova data) e regressão dos demais Flows SOL.
 */
@IsTest
private class SOLProcuracaoAcompanhamentoTest {
  private static final String FILA_SINTETICA = 'RR_Procuracao_SOL_9426';
  private static final String CNPJ = '11222333000181';
  private static final String STATUS_INICIAL = 'Captação - Contato';
  private static final String STATUS_PROC = 'Procuração Solicitada';
  private static final String TIPO = 'Acompanhamento da procuração';
  private static final String SUBJECT = 'Acompanhar recebimento da procuração';
  private static final String TZ_SP = 'America/Sao_Paulo';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
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

  private static User vendedor(Integer i) {
    return new User(
      FirstName = 'RR',
      LastName = 'ProcVend ' + i,
      Alias = ('rrp' + i).left(8),
      Email = 'rr.rp' + i + '@arnone.invalid',
      Username = 'rr.rp' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9426.test.invalid',
      ProfileId = profileStandardId(),
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
        Name = 'RR Procuracao SOL 9426',
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
      SELECT
        Id,
        OwnerId,
        Status,
        IsConverted,
        SOL_Produto_Interesse__c,
        SOL_Status_Procuracao__c,
        SOL_Data_Solicitacao_Procuracao__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  /** Mesmas gravações que SOL_Procuracao.Registrar_Solicitacao faz no Lead. */
  private static void registrarSolicitacao(Id leadId, Date data) {
    update new Lead(
      Id = leadId,
      Status = STATUS_PROC,
      SOL_Status_Procuracao__c = 'Solicitada',
      SOL_Data_Solicitacao_Procuracao__c = data
    );
  }

  private static List<Task> tarefas(Id leadId) {
    return [
      SELECT
        Id,
        Subject,
        Status,
        OwnerId,
        WhoId,
        ActivityDate,
        SOL_Tipo_Tarefa__c,
        SOL_Data_Solicitacao_Ref__c
      FROM Task
      WHERE WhoId = :leadId AND SOL_Tipo_Tarefa__c = :TIPO
    ];
  }

  private static Task tarefaAcompanhamento(Id leadId, Id owner, Date ref, String status) {
    Task t = new Task(
      Subject = 'acompanhamento pré-existente',
      WhoId = leadId,
      OwnerId = owner,
      Status = status,
      ActivityDate = Date.today().addDays(3),
      SOL_Tipo_Tarefa__c = TIPO,
      SOL_Data_Solicitacao_Ref__c = ref
    );
    insert t;
    return t;
  }

  private static Id bhId() {
    Id v = SOLBusinessHoursHelper.businessHoursId();
    System.assertNotEquals(null, v, 'Business Hours comercial é pré-requisito.');
    return v;
  }

  private static Date vencimentoEsperado(Date solicitacao) {
    return SOLBusinessHoursHelper.dataEm(
      SOLBusinessHoursHelper.prazoEmDiasUteis(bhId(), solicitacao, 7),
      TZ_SP
    );
  }

  // ============================================================ POSITIVO

  @IsTest
  static void criaTarefa_RecuperacaoTributaria() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOL('S1', 'Recuperação Tributária');
    Date hoje = Date.today();

    Test.startTest();
    registrarSolicitacao(l.Id, hoje);
    Test.stopTest();

    List<Task> ts = tarefas(l.Id);
    System.assertEquals(1, ts.size(), 'Uma tarefa de acompanhamento.');
    System.assertEquals(SUBJECT, ts[0].Subject);
    System.assertEquals('Open', ts[0].Status);
    System.assertEquals(l.Id, ts[0].WhoId);
    System.assertEquals(l.OwnerId, ts[0].OwnerId, 'Proprietário = dono atual do Lead.');
    System.assertEquals(TIPO, ts[0].SOL_Tipo_Tarefa__c);
    System.assertEquals(hoje, ts[0].SOL_Data_Solicitacao_Ref__c, 'Referência = data da solicitação.');
    System.assertEquals(vencimentoEsperado(hoje), ts[0].ActivityDate, '7 dias úteis após a solicitação.');
    // Não altera o Status do Lead.
    System.assertEquals(STATUS_PROC, recarregar(l.Id).Status);
  }

  @IsTest
  static void criaTarefa_ART360() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S2', 'ART 360');

    Test.startTest();
    registrarSolicitacao(l.Id, Date.today());
    Test.stopTest();

    System.assertEquals(1, tarefas(l.Id).size(), 'ART 360 também exige procuração — cria a tarefa.');
  }

  @IsTest
  static void proprietarioAcompanhaODonoAtual() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOL('S3', 'ART 360');
    Id outro = c.vendedores[0] == l.OwnerId ? c.vendedores[1] : c.vendedores[0];
    update new Lead(Id = l.Id, OwnerId = outro);

    Test.startTest();
    registrarSolicitacao(l.Id, Date.today());
    Test.stopTest();

    List<Task> ts = tarefas(l.Id);
    System.assertEquals(1, ts.size());
    System.assertEquals(outro, ts[0].OwnerId);
  }

  // ============================================================ NÃO APLICA

  @IsTest
  static void somenteStatusSemSolicitacaoNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S4', 'Recuperação Tributária');

    Test.startTest();
    // Status muda, mas sem o campo de status da procuração nem a data.
    update new Lead(Id = l.Id, Status = STATUS_PROC);
    Test.stopTest();

    System.assertEquals(0, tarefas(l.Id).size(), 'Sem os três sinais, nada é criado.');
  }

  @IsTest
  static void statusProcuracaoSemDataNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S4b', 'ART 360');

    Test.startTest();
    update new Lead(
      Id = l.Id,
      Status = STATUS_PROC,
      SOL_Status_Procuracao__c = 'Solicitada'
      // sem SOL_Data_Solicitacao_Procuracao__c
    );
    // chamada direta também ignora
    SOLProcuracaoAcompanhamentoService.ResultadoAcompanhamento rr = SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, rr.tarefasCriadas);
    System.assertEquals(0, tarefas(l.Id).size());
  }

  @IsTest
  static void atualizacaoNaoRelacionadaNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S5', 'Recuperação Tributária');
    registrarSolicitacao(l.Id, Date.today());
    System.assertEquals(1, tarefas(l.Id).size());

    Test.startTest();
    update new Lead(Id = l.Id, Description = 'edição qualquer');
    Test.stopTest();

    System.assertEquals(1, tarefas(l.Id).size(), 'Atualização não relacionada não cria outra.');
  }

  @IsTest
  static void outraBUNaoCria() {
    Cenario c = montarCenario(2);
    Lead outra = new Lead(LastName = 'OutraBU', Company = 'C');
    insert outra;

    Test.startTest();
    SOLProcuracaoAcompanhamentoService.ResultadoAcompanhamento r = SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(
      new List<Id>{ outra.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas);
    System.assert(r.ignorados >= 1);
  }

  @IsTest
  static void produtoForaDoEscopoNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S6', null); // produto em branco

    Test.startTest();
    registrarSolicitacao(l.Id, Date.today());
    Test.stopTest();

    System.assertEquals(0, tarefas(l.Id).size());
  }

  @IsTest
  static void leadConvertidoNaoCria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S7', 'Recuperação Tributária');
    update new Lead(Id = l.Id, SOL_Status_Procuracao__c = 'Recebida');
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1].MasterLabel
    );
    Database.convertLead(lc);

    Test.startTest();
    SOLProcuracaoAcompanhamentoService.ResultadoAcompanhamento r = SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    System.assertEquals(0, r.tarefasCriadas);
    System.assert(r.ignorados >= 1);
  }

  // ============================================================ IDENTIDADE DA SOLICITAÇÃO

  @IsTest
  static void reprocessamentoDaMesmaSolicitacaoNaoDuplica() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S8', 'ART 360');
    Date hoje = Date.today();

    Test.startTest();
    registrarSolicitacao(l.Id, hoje);
    SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>{ l.Id });
    SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertEquals(1, tarefas(l.Id).size(), 'Mesma solicitação: no máximo uma tarefa.');
  }

  @IsTest
  static void reentradaNoStatusMesmaSolicitacaoNaoDuplica() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S9', 'Recuperação Tributária');
    Date hoje = Date.today();
    registrarSolicitacao(l.Id, hoje);
    System.assertEquals(1, tarefas(l.Id).size());

    Test.startTest();
    update new Lead(Id = l.Id, Status = 'Reunião Agendada - SQL');
    // volta para "Procuração Solicitada" com a MESMA data de solicitação
    update new Lead(
      Id = l.Id,
      Status = STATUS_PROC,
      SOL_Status_Procuracao__c = 'Solicitada',
      SOL_Data_Solicitacao_Procuracao__c = hoje
    );
    Test.stopTest();

    System.assertEquals(1, tarefas(l.Id).size(), 'Reentrada na mesma solicitação não duplica.');
  }

  @IsTest
  static void tarefaEncerradaDaMesmaSolicitacaoNaoRecria() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S10', 'ART 360');
    Date hoje = Date.today();
    tarefaAcompanhamento(l.Id, l.OwnerId, hoje, 'Completed');

    Test.startTest();
    registrarSolicitacao(l.Id, hoje);
    Test.stopTest();

    List<Task> ts = tarefas(l.Id);
    System.assertEquals(1, ts.size(), 'Tarefa encerrada da mesma solicitação conta — não recria.');
    System.assertEquals('Completed', ts[0].Status);
  }

  @IsTest
  static void tarefaAbertaDaMesmaSolicitacaoNaoDuplica() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S10b', 'Recuperação Tributária');
    Date hoje = Date.today();
    tarefaAcompanhamento(l.Id, l.OwnerId, hoje, 'Open');

    Test.startTest();
    registrarSolicitacao(l.Id, hoje);
    Test.stopTest();

    System.assertEquals(1, tarefas(l.Id).size());
  }

  @IsTest
  static void novaSolicitacaoComNovaDataCriaNovaTarefa() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S11', 'Recuperação Tributária');
    Date d1 = Date.today().addDays(-10);
    Date d2 = Date.today();

    // 1ª solicitação (data antiga) — tarefa já encerrada
    tarefaAcompanhamento(l.Id, l.OwnerId, d1, 'Completed');

    Test.startTest();
    // 2ª solicitação, nova data
    registrarSolicitacao(l.Id, d2);
    Test.stopTest();

    List<Task> ts = tarefas(l.Id);
    System.assertEquals(2, ts.size(), 'Nova solicitação (nova data) gera nova tarefa.');
    Set<Date> refs = new Set<Date>();
    for (Task t : ts) {
      refs.add(t.SOL_Data_Solicitacao_Ref__c);
    }
    System.assert(refs.contains(d1) && refs.contains(d2), 'Uma tarefa por solicitação: ' + refs);
  }

  // ======================================= BULK / IDEMPOTÊNCIA SEQUENCIAL
  //
  // Concorrência real (duas transações paralelas para o mesmo Lead) NÃO é
  // simulável em teste Apex. A proteção é o SELECT ... FOR UPDATE em
  // criarTarefaAcompanhamento, que serializa as transações no nível do banco.
  // Os testes abaixo cobrem só a idempotência SEQUENCIAL (chamadas repetidas
  // na mesma transação).

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

    List<Lead> upd = new List<Lead>();
    for (Lead l : leads) {
      upd.add(
        new Lead(
          Id = l.Id,
          Status = STATUS_PROC,
          SOL_Status_Procuracao__c = 'Solicitada',
          SOL_Data_Solicitacao_Procuracao__c = Date.today()
        )
      );
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    update upd;
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(
      12,
      [SELECT COUNT() FROM Task WHERE WhoId IN :leads AND SOL_Tipo_Tarefa__c = :TIPO]
    );
    System.assert(soql < 25, 'SOQL não escala por Lead: ' + soql);
    System.assert(dml < 12, 'DML não escala por Lead: ' + dml);
  }

  @IsTest
  static void duasChamadasNaMesmaTransacaoCriamUmaSo() {
    // Idempotência SEQUENCIAL — NÃO é teste de concorrência (ver nota da seção).
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S12', 'ART 360');
    registrarSolicitacao(l.Id, Date.today());

    Test.startTest();
    SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>{ l.Id });
    SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertEquals(1, tarefas(l.Id).size());
  }

  // ============================================================ PRAZO / CALENDÁRIO
  //
  // FERIADO: a implementação delega a BusinessHours.nextStartDate, que respeita
  // os feriados associados ao calendário. NÃO há teste automatizado direto com
  // um Holiday: um Holiday inserido no teste não se associa a um Business Hours
  // não-default e, portanto, não afetaria BusinessHours.nextStartDate aqui.
  // Cobertura de feriado = configurar o calendário em Setup (fora do código).

  @IsTest
  static void prazoContaSextaComExpedienteReduzido() {
    Id bh = bhId();
    // Quinta 2026-09-10. Dias úteis após: 11(sex, fecha 17h) 14 15 16 17 18 21.
    Date origem = Date.newInstance(2026, 9, 10);
    Datetime prazo = SOLBusinessHoursHelper.prazoEmDiasUteis(bh, origem, 7);
    System.assertEquals(
      Date.newInstance(2026, 9, 21),
      SOLBusinessHoursHelper.dataEm(prazo, TZ_SP),
      'A sexta 09-11 (expediente reduzido) conta como dia útil.'
    );
    // A sobrecarga de Date equivale a ancorar ao meio-dia GMT.
    System.assertEquals(
      prazo,
      SOLBusinessHoursHelper.prazoEmDiasUteis(
        bh,
        Datetime.newInstanceGmt(origem, Time.newInstance(12, 0, 0, 0)),
        7
      )
    );
  }

  @IsTest
  static void prazoOrigemNoFimDeSemana() {
    Id bh = bhId();
    // Sábado 2026-09-12. Dias úteis após: 14 15 16 17 18 21 22.
    System.assertEquals(
      Date.newInstance(2026, 9, 22),
      SOLBusinessHoursHelper.dataEm(
        SOLBusinessHoursHelper.prazoEmDiasUteis(bh, Date.newInstance(2026, 9, 12), 7),
        TZ_SP
      )
    );
  }

  @IsTest
  static void activityDateSemDeslocamentoDeTimezone() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('SPrazo', 'Recuperação Tributária');
    // Solicitação numa QUARTA => 7º dia útil numa SEXTA (2026-09-11).
    Date solic = Date.newInstance(2026, 9, 2);

    Test.startTest();
    registrarSolicitacao(l.Id, solic);
    Test.stopTest();

    List<Task> ts = tarefas(l.Id);
    System.assertEquals(1, ts.size());
    System.assertEquals(
      Date.newInstance(2026, 9, 11),
      ts[0].ActivityDate,
      'Vencimento = data (São Paulo) do 7º dia útil, sem deslocamento GMT.'
    );
    System.assertEquals(solic, ts[0].SOL_Data_Solicitacao_Ref__c);
  }

  @IsTest
  static void prazoSeteDiasUteisRegressao() {
    Id bh = bhId();
    Date origem = Date.newInstance(2026, 3, 3); // terça
    Date venc = SOLBusinessHoursHelper.dataEm(
      SOLBusinessHoursHelper.prazoEmDiasUteis(bh, origem, 7),
      TZ_SP
    );
    Integer uteis = 0;
    Integer naoUteis = 0;
    Date d = origem;
    while (d < venc) {
      d = d.addDays(1);
      Datetime antes = Datetime.newInstanceGmt(d, Time.newInstance(0, 0, 0, 0));
      Datetime prox = BusinessHours.nextStartDate(bh, antes);
      if (prox != null && SOLBusinessHoursHelper.dataEm(prox, TZ_SP) == d) {
        uteis++;
      } else {
        naoUteis++;
      }
    }
    System.assertEquals(7, uteis, 'Exatamente 7 dias úteis no intervalo (solicitação, vencimento].');
    System.assert(naoUteis >= 2, 'Pelo menos um fim de semana pulado.');
    System.assert(origem.daysBetween(venc) >= 9, '7 dias úteis = pelo menos 9 dias corridos.');
  }

  @IsTest
  static void calendarioAusenteAbortaComRollback() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S13', 'Recuperação Tributária');

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    Boolean lancou = false;
    try {
      registrarSolicitacao(l.Id, Date.today());
    } catch (Exception e) {
      lancou = true;
      System.assert(
        e.getMessage().contains('calendário'),
        'Mensagem controlada de calendário ausente: ' + e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(lancou, 'Calendário ausente aborta com exceção controlada.');
    System.assertEquals(0, tarefas(l.Id).size());
    Lead d = recarregar(l.Id);
    System.assertEquals(STATUS_INICIAL, d.Status, 'O registro da solicitação foi desfeito (atômico).');
    System.assertEquals(null, d.SOL_Status_Procuracao__c, 'Campo de status da procuração revertido.');
    System.assertEquals(null, d.SOL_Data_Solicitacao_Procuracao__c, 'Data revertida.');
  }

  // ============================================================ ATOMICIDADE

  @IsTest
  static void falhaNaCriacaoAbortaAtomicamente() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S14', 'ART 360');
    registrarSolicitacao(l.Id, Date.today());
    delete tarefas(l.Id);

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>{ l.Id });
    } catch (SOLProcuracaoAcompanhamentoService.AcompanhamentoException e) {
      lancou = true;
      System.assertEquals(SOLProcuracaoAcompanhamentoService.MSG_FALHA, e.getMessage());
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(lancou, 'Falha relança AcompanhamentoException.');
    System.assertEquals(0, tarefas(l.Id).size());
  }

  @IsTest
  static void invocableRelancaAFalha() {
    Cenario c = montarCenario(2);
    Lead l = novoLeadSOL('S15', 'ART 360');
    registrarSolicitacao(l.Id, Date.today());
    delete tarefas(l.Id);

    SOLProcuracaoAcompanhamentoInvocable.Entrada e = new SOLProcuracaoAcompanhamentoInvocable.Entrada();
    e.leadId = l.Id;

    Test.startTest();
    SOLBusinessHoursHelper.overrideBusinessHours(null);
    Boolean lancou = false;
    try {
      SOLProcuracaoAcompanhamentoInvocable.criar(
        new List<SOLProcuracaoAcompanhamentoInvocable.Entrada>{ e }
      );
    } catch (SOLProcuracaoAcompanhamentoService.AcompanhamentoException ex) {
      lancou = true;
    }
    Test.stopTest();

    System.assert(lancou, 'O Invocable relança a falha para o Flow abortar a transação.');
  }

  @IsTest
  static void invocableIgnoraEntradasInvalidas() {
    Test.startTest();
    SOLProcuracaoAcompanhamentoInvocable.criar(null);
    SOLProcuracaoAcompanhamentoInvocable.criar(
      new List<SOLProcuracaoAcompanhamentoInvocable.Entrada>()
    );
    SOLProcuracaoAcompanhamentoInvocable.Entrada semId = new SOLProcuracaoAcompanhamentoInvocable.Entrada();
    semId.leadId = null;
    SOLProcuracaoAcompanhamentoInvocable.criar(
      new List<SOLProcuracaoAcompanhamentoInvocable.Entrada>{ semId, null }
    );
    Test.stopTest();

    System.assertEquals(0, [SELECT COUNT() FROM Task WHERE SOL_Tipo_Tarefa__c = :TIPO]);
  }

  @IsTest
  static void colecaoVaziaOuNulaEhNoOp() {
    Test.startTest();
    SOLProcuracaoAcompanhamentoService.ResultadoAcompanhamento r1 = SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(null);
    SOLProcuracaoAcompanhamentoService.ResultadoAcompanhamento r2 = SOLProcuracaoAcompanhamentoService.criarTarefaAcompanhamento(new List<Id>());
    Test.stopTest();
    System.assertEquals(0, r1.tarefasCriadas);
    System.assertEquals(0, r2.tarefasCriadas);
  }

  // ============================================================ VENDEDOR COMERCIAL

  private static Id psSolComercialId() {
    return [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id;
  }

  @IsTest
  static void vendedorComercialRegistraSolicitacaoEDisparaApex() {
    User comercial = vendedor(99);
    System.runAs(contextoAtual()) {
      insert comercial;
      insert new PermissionSetAssignment(
        AssigneeId = comercial.Id,
        PermissionSetId = psSolComercialId()
      );
      Group fila = new Group(
        Name = 'RR Procuracao Comercial 9426',
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
    System.runAs(new User(Id = comercial.Id)) {
      update new Lead(
        Id = l.Id,
        Status = STATUS_PROC,
        SOL_Status_Procuracao__c = 'Solicitada',
        SOL_Data_Solicitacao_Procuracao__c = Date.today()
      );
    }
    Test.stopTest();

    List<Task> ts = tarefas(l.Id);
    System.assertEquals(1, ts.size(), 'Vendedor comercial registra a solicitação e o Apex cria a tarefa.');
    System.assertEquals(comercial.Id, ts[0].OwnerId);

    System.runAs(new User(Id = comercial.Id)) {
      Schema.DescribeFieldResult f = Schema.SObjectType.Task.fields.getMap()
        .get('SOL_Data_Solicitacao_Ref__c')
        .getDescribe();
      System.assert(f.isAccessible(), 'Vendedor enxerga SOL_Data_Solicitacao_Ref__c.');
      System.assert(!f.isUpdateable(), 'SOL_Data_Solicitacao_Ref__c é somente leitura para o vendedor.');
    }
  }

  // ============================================================ REGRESSÃO

  @IsTest
  static void regressaoReuniaoContatoOptOutDistribuicao() {
    Cenario c = montarCenario(3);

    // Distribuição continua criando a "1ª Ligação".
    Lead lReuniao = novoLeadSOL('Reg1', 'ART 360');
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :lReuniao.Id AND Subject = '1ª Ligação'],
      'Distribuição SOL intacta.'
    );

    Test.startTest();
    // CLICKUP-9401: reunião agendada -> tarefa de reunião.
    update new Lead(Id = lReuniao.Id, Status = 'Reunião Agendada - SQL');
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :lReuniao.Id AND SOL_Tipo_Tarefa__c = 'Reunião comercial'],
      'PR #8 (tarefa de reunião) intacto.'
    );

    // CLICKUP-9417: contato efetivado.
    Lead lContato = novoLeadSOL('Reg2', 'ART 360');
    update new Task(
      Id = [SELECT Id FROM Task WHERE WhoId = :lContato.Id AND Subject = '1ª Ligação' LIMIT 1].Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
    System.assertEquals(
      true,
      [SELECT SOL_Contato_Efetivado__c FROM Lead WHERE Id = :lContato.Id].SOL_Contato_Efetivado__c,
      'Flow SOL_Contato_Efetivado intacto.'
    );

    // CLICKUP-9418: opt-out.
    Lead lOpt = novoLeadSOL('Reg3', 'ART 360');
    update new Task(
      Id = [SELECT Id FROM Task WHERE WhoId = :lOpt.Id AND Subject = '1ª Ligação' LIMIT 1].Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Opt-out'
    );
    Test.stopTest();

    System.assertEquals(
      'Desqualificado',
      [SELECT Status FROM Lead WHERE Id = :lOpt.Id].Status,
      'Flow SOL_Opt_Out intacto.'
    );
    // E o opt-out não gerou tarefa de acompanhamento de procuração.
    System.assertEquals(0, tarefas(lOpt.Id).size());
  }

  @IsTest
  static void regressaoReatribuicaoPorFaltaDeContato() {
    Cenario c = montarCenario(3);
    Lead l = novoLeadSOL('Reg4', 'ART 360');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    insert new List<Task>{
      new Task(WhoId = l.Id, Subject = 'n1', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n2', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n3', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu')
    };
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertNotEquals(
      ownerInicial,
      [SELECT OwnerId FROM Lead WHERE Id = :l.Id].OwnerId,
      'CLICKUP-9400 (reatribuição por falta de contato) intacto.'
    );
  }
}
