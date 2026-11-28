/**
 * CLICKUP-11813 — Nutrição, desqualificação e reunião sem avanço no Lead da S Company.
 * Cobre as VRs SCO_Nutricao_Exige_Motivo_E_Retomada, SCO_Nutricao_Exige_Data_Retomada_Futura,
 * SCO_Desqualificado_Exige_Motivo e SCO_Reuniao_Sem_Avanco_Exige_Motivo, o reengajamento
 * (volta para "Em contato" sem limpar o histórico) e o isolamento das outras unidades.
 *
 * CLICKUP-12121 (v4): valores novos dos motivos, observação obrigatória com "Outros"
 * (SCO_Desqualif_Outros_Exige_Observacao), motivos só preenchíveis no próprio status
 * (SCO_Motivo_Nutricao_So_Em_Nutricao, SCO_Motivo_Desqualif_So_Desqualificado), Email Opt Out ao
 * desqualificar com "Solicitou não ser contatado" (flow SCO_Lead_Optout_Ao_Desqualificar) e a tarefa
 * "Retomar contato" (subflow SCO_Lead_Criar_Tarefa_Retomada, agendado pelo SCO_Lead_Agendar_Retomada).
 * Os cenários T1..T14 rodam com a persona BDR (Standard User + PS_SCO_Comercial, papel Comercial_SCO).
 */
@IsTest
private class SCONutricaoDesqualificacaoLeadTest {
  private static final String MSG_MOTIVO_NUTRICAO = 'Informe o motivo da nutrição.';
  private static final String MSG_DATA_RETOMADA = 'Informe a data de retomada.';
  private static final String MSG_MOTIVO_DESQ = 'Informe o motivo da desqualificação.';
  private static final String MSG_REUNIAO_SEM_AVANCO = 'Informe o motivo da reunião sem avanço.';
  private static final String MSG_OBS_OUTROS = 'Descreva o motivo na observação.';
  private static final String MSG_NUTRICAO_SO_EM_NUTRICAO = 'O motivo da nutrição só pode ser informado no status Em nutrição.';
  private static final String MSG_DESQ_SO_DESQUALIFICADO = 'O motivo da desqualificação só pode ser informado no status Desqualificado.';
  private static final String ASSUNTO_RETOMADA = 'Retomar contato';
  private static final String CNPJ_SOL = '11222333000181';

  private static Id rt(String devName) {
    return Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName()
      .get(devName)
      .getRecordTypeId();
  }

  private static Lead leadSco(String status, Date reuniaoRealizada) {
    Lead l = new Lead(
      RecordTypeId = rt('SCO'),
      LastName = 'Lead Nutricao SCO',
      Company = 'Empresa Nutricao SCO',
      LeadSource = 'Indicacao',
      Status = status,
      SCO_Data_Reuniao_Realizada__c = reuniaoRealizada
    );
    insert l;
    return l;
  }

  private static Lead recarregar(Id leadId) {
    return [
      SELECT
        Id,
        Status,
        SCO_Motivo_Nutricao__c,
        SCO_Data_Retomada__c,
        SCO_Motivo_Desqualificacao__c,
        SCO_Observacao_Desqualificacao__c,
        SCO_Motivo_Reuniao_Sem_Avanco__c
      FROM Lead
      WHERE Id = :leadId
    ];
  }

  private static String erroAoAtualizar(Lead l) {
    try {
      update l;
    } catch (DmlException e) {
      return e.getMessage();
    }
    return null;
  }

  private static void assertErro(String erro, String esperado) {
    System.assert(erro != null && erro.contains(esperado), 'Esperado "' + esperado + '", veio: ' + erro);
  }

  // 1. Caminho feliz: "Em contato" -> "Em nutrição" com motivo e retomada em 60 dias.
  @IsTest
  static void nutricaoCaminhoFeliz() {
    Lead l = leadSco('Em contato', null);

    Test.startTest();
    String erro = erroAoAtualizar(
      new Lead(
        Id = l.Id,
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Sem retorno',
        SCO_Data_Retomada__c = Date.today().addDays(60)
      )
    );
    Test.stopTest();

    System.assertEquals(null, erro);
    Lead depois = recarregar(l.Id);
    System.assertEquals('Em nutrição', depois.Status);
    System.assertEquals('Sem retorno', depois.SCO_Motivo_Nutricao__c);
    System.assertEquals(Date.today().addDays(60), depois.SCO_Data_Retomada__c);
  }

  // 2. Nutrição sem data de retomada é bloqueada; sem motivo também.
  @IsTest
  static void nutricaoSemDataOuMotivoBloqueia() {
    Lead l = leadSco('Em contato', null);

    Test.startTest();
    String semData = erroAoAtualizar(
      new Lead(Id = l.Id, Status = 'Em nutrição', SCO_Motivo_Nutricao__c = 'Sem timing')
    );
    String semMotivo = erroAoAtualizar(
      new Lead(Id = l.Id, Status = 'Em nutrição', SCO_Data_Retomada__c = Date.today().addDays(10))
    );
    Test.stopTest();

    assertErro(semData, MSG_DATA_RETOMADA);
    assertErro(semMotivo, MSG_MOTIVO_NUTRICAO);
    System.assertEquals('Em contato', recarregar(l.Id).Status);
  }

  // 3. Data de retomada hoje ou no passado é bloqueada (também na criação já em nutrição).
  @IsTest
  static void dataRetomadaHojeOuPassadoBloqueia() {
    Lead l = leadSco('Em contato', null);

    Test.startTest();
    String hoje = erroAoAtualizar(
      new Lead(
        Id = l.Id,
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Sem timing',
        SCO_Data_Retomada__c = Date.today()
      )
    );
    String passado = erroAoAtualizar(
      new Lead(
        Id = l.Id,
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Sem timing',
        SCO_Data_Retomada__c = Date.today().addDays(-1)
      )
    );
    String naCriacao;
    try {
      insert new Lead(
        RecordTypeId = rt('SCO'),
        LastName = 'Lead Criado Nutricao',
        Company = 'Empresa Criada Nutricao',
        LeadSource = 'Indicacao',
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Sem timing',
        SCO_Data_Retomada__c = Date.today()
      );
    } catch (DmlException e) {
      naCriacao = e.getMessage();
    }
    Test.stopTest();

    assertErro(hoje, MSG_DATA_RETOMADA);
    assertErro(passado, MSG_DATA_RETOMADA);
    assertErro(naCriacao, MSG_DATA_RETOMADA);
  }

  // 4. "Desqualificado" exige motivo; com "Outros" a observação passa a ser obrigatória (CLICKUP-12121).
  @IsTest
  static void desqualificadoExigeMotivoEObservacaoComOutros() {
    Lead l = leadSco('Em contato', null);

    Test.startTest();
    String semMotivo = erroAoAtualizar(new Lead(Id = l.Id, Status = 'Desqualificado'));
    String outrosSemObs = erroAoAtualizar(
      new Lead(Id = l.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Outros')
    );
    String outrosComObs = erroAoAtualizar(
      new Lead(
        Id = l.Id,
        Status = 'Desqualificado',
        SCO_Motivo_Desqualificacao__c = 'Outros',
        SCO_Observacao_Desqualificacao__c = 'Empresa em recuperação judicial.'
      )
    );
    Test.stopTest();

    assertErro(semMotivo, MSG_MOTIVO_DESQ);
    assertErro(outrosSemObs, MSG_OBS_OUTROS);
    Assert.isNull(outrosComObs, 'Com observação, "Outros" deve salvar.');
    Lead depois = recarregar(l.Id);
    Assert.areEqual('Desqualificado', depois.Status, 'Status gravado');
    Assert.areEqual('Empresa em recuperação judicial.', depois.SCO_Observacao_Desqualificacao__c, 'Observação gravada');
  }

  // 5a. Reunião realizada -> "Em nutrição" exige motivo da reunião sem avanço.
  @IsTest
  static void reuniaoRealizadaParaNutricaoExigeMotivo() {
    Lead l = leadSco('Em contato', Date.today().addDays(-2));
    Lead nutricao = new Lead(
      Id = l.Id,
      Status = 'Em nutrição',
      SCO_Motivo_Nutricao__c = 'Sem orçamento no momento',
      SCO_Data_Retomada__c = Date.today().addDays(90)
    );

    Test.startTest();
    String bloqueado = erroAoAtualizar(nutricao);
    nutricao.SCO_Motivo_Reuniao_Sem_Avanco__c = 'Cliente sem orçamento neste semestre.';
    String liberado = erroAoAtualizar(nutricao);
    Test.stopTest();

    assertErro(bloqueado, MSG_REUNIAO_SEM_AVANCO);
    System.assertEquals(null, liberado);
    System.assertEquals('Em nutrição', recarregar(l.Id).Status);
  }

  // 5b. Reunião realizada -> "Desqualificado" exige motivo da reunião sem avanço.
  @IsTest
  static void reuniaoRealizadaParaDesqualificadoExigeMotivo() {
    Lead l = leadSco('Em contato', Date.today());
    Lead desq = new Lead(Id = l.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Fora do perfil');

    Test.startTest();
    String bloqueado = erroAoAtualizar(desq);
    desq.SCO_Motivo_Reuniao_Sem_Avanco__c = 'Empresa com menos de 50 colaboradores.';
    String liberado = erroAoAtualizar(desq);
    Test.stopTest();

    assertErro(bloqueado, MSG_REUNIAO_SEM_AVANCO);
    System.assertEquals(null, liberado);
    System.assertEquals('Desqualificado', recarregar(l.Id).Status);
  }

  // 6. Sem reunião realizada, nutrição e desqualificação não pedem o motivo da reunião.
  @IsTest
  static void semReuniaoRealizadaNaoExigeMotivoReuniao() {
    Lead a = leadSco('Em contato', null);
    Lead b = leadSco('Em contato', null);

    Test.startTest();
    String nutricao = erroAoAtualizar(
      new Lead(
        Id = a.Id,
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Decisor não identificado',
        SCO_Data_Retomada__c = Date.today().addDays(15)
      )
    );
    String desq = erroAoAtualizar(
      new Lead(Id = b.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Empresa inexistente ou fechada')
    );
    Test.stopTest();

    System.assertEquals(null, nutricao);
    System.assertEquals(null, desq);
  }

  // 7. Reengajamento: "Em nutrição" -> "Em contato" sem trava, motivo e data preservados.
  @IsTest
  static void reengajamentoPreservaHistorico() {
    Lead l = leadSco('Em contato', null);
    Date retomada = Date.today().addDays(60);
    update new Lead(
      Id = l.Id,
      Status = 'Em nutrição',
      SCO_Motivo_Nutricao__c = 'Sem retorno',
      SCO_Data_Retomada__c = retomada
    );

    Test.startTest();
    String erro = erroAoAtualizar(new Lead(Id = l.Id, Status = 'Em contato'));
    Test.stopTest();

    System.assertEquals(null, erro);
    Lead depois = recarregar(l.Id);
    System.assertEquals('Em contato', depois.Status);
    System.assertEquals('Sem retorno', depois.SCO_Motivo_Nutricao__c, 'O motivo anterior não pode ser limpo.');
    System.assertEquals(retomada, depois.SCO_Data_Retomada__c, 'A data anterior não pode ser limpa.');
  }

  // 8. Isolamento: SOL desqualifica com as regras dela; ADV, ESG e STE seguem sem as VRs SCO.
  @IsTest
  static void outrasUnidadesNaoSaoAfetadas() {
    Lead sol = new Lead(
      RecordTypeId = rt('SOL'),
      LastName = 'Lead SOL Isolamento',
      Company = 'Empresa SOL Isolamento',
      Status = 'Recebido - MQL',
      CNPJ__c = CNPJ_SOL
    );
    List<Lead> outros = new List<Lead>();
    for (String bu : new List<String>{ 'ADV', 'ESG', 'STE' }) {
      outros.add(
        new Lead(RecordTypeId = rt(bu), LastName = 'Lead ' + bu, Company = 'Empresa ' + bu, Status = 'Novo')
      );
    }
    insert sol;
    insert outros;

    Test.startTest();
    // Lead SOL: a regra SOL continua exigindo o motivo SOL...
    String solSemMotivo = erroAoAtualizar(
      new Lead(Id = sol.Id, Status = 'Desqualificado', SCO_Data_Reuniao_Realizada__c = Date.today())
    );
    // ...e com o motivo SOL desqualifica, sem nenhum campo SCO preenchido.
    String solComMotivo = erroAoAtualizar(
      new Lead(
        Id = sol.Id,
        Status = 'Desqualificado',
        SOL_Motivo_Desqualificacao__c = 'Negócio perdido',
        SCO_Data_Reuniao_Realizada__c = Date.today()
      )
    );
    for (Lead l : outros) {
      l.Status = 'Desqualificado';
      l.SCO_Data_Reuniao_Realizada__c = Date.today();
    }
    update outros;
    Test.stopTest();

    System.assert(solSemMotivo != null && !solSemMotivo.contains(MSG_MOTIVO_DESQ), solSemMotivo);
    System.assert(!solSemMotivo.contains(MSG_REUNIAO_SEM_AVANCO), solSemMotivo);
    System.assertEquals(null, solComMotivo);
    Lead solDepois = [SELECT Status, SOL_Motivo_Desqualificacao__c, SCO_Motivo_Desqualificacao__c FROM Lead WHERE Id = :sol.Id];
    System.assertEquals('Desqualificado', solDepois.Status);
    System.assertEquals('Negócio perdido', solDepois.SOL_Motivo_Desqualificacao__c);
    System.assertEquals(null, solDepois.SCO_Motivo_Desqualificacao__c);
    for (Lead l : [SELECT Status FROM Lead WHERE Id IN :outros]) {
      System.assertEquals('Desqualificado', l.Status);
    }
  }

  // ---------------------------------------------------------------------------
  // CLICKUP-12121 — cenários v4 por persona (T1..T14).
  // ---------------------------------------------------------------------------

  /** Standard User + PS_SCO_Comercial no papel Comercial_SCO. Inserido como setup para evitar MIXED_DML. */
  private static User persona(String sufixo) {
    Id perfilId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
    Id papelId = [SELECT Id FROM UserRole WHERE DeveloperName = 'Comercial_SCO' LIMIT 1].Id;
    Id psId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SCO_Comercial' LIMIT 1].Id;
    String unico = String.valueOf(Math.abs(Crypto.getRandomInteger()));
    User u = new User(
      FirstName = 'SCO',
      LastName = 'BDR 12121 ' + sufixo,
      Alias = ('s21' + sufixo).left(8),
      Email = 'sco.12121.' + sufixo + '@arnone.invalid',
      Username = 'sco.12121.' + sufixo + '.' + unico + '@arnone.nutricao.test.invalid',
      ProfileId = perfilId,
      UserRoleId = papelId,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
      insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = psId);
    }
    return u;
  }

  /** Lead SCO criado pelo próprio BDR (dono), com nome único para não acionar regras de duplicidade. */
  private static Lead leadDoBdr(User b, String marca, String status) {
    Lead l = new Lead(
      RecordTypeId = rt('SCO'),
      LastName = 'Lead 12121 ' + marca,
      Company = 'Empresa 12121 ' + marca,
      LeadSource = 'Indicacao',
      Status = status
    );
    System.runAs(b) {
      insert l;
    }
    return l;
  }

  private static String erroComo(User u, Lead l) {
    String erro;
    System.runAs(u) {
      erro = erroAoAtualizar(l);
    }
    return erro;
  }

  private static Boolean optOut(Id leadId) {
    return [SELECT HasOptedOutOfEmail FROM Lead WHERE Id = :leadId].HasOptedOutOfEmail;
  }

  private static List<Task> tarefasRetomada(Id leadId) {
    return [
      SELECT Id, OwnerId, ActivityDate, Description, IsClosed
      FROM Task
      WHERE WhoId = :leadId AND Subject = :ASSUNTO_RETOMADA
    ];
  }

  private static void rodarSubflowRetomada(Id leadId, Date referencia) {
    Map<String, Object> entradas = new Map<String, Object>{ 'recordId' => leadId, 'dataReferencia' => referencia };
    Flow.Interview.createInterview('SCO_Lead_Criar_Tarefa_Retomada', entradas).start();
  }

  /** Lead SCO inserido já em "Em nutrição", com retomada amanhã, dono e BDR responsável informados. */
  private static Lead leadEmNutricaoAmanha(String marca, Id ownerId, Id bdrResponsavelId) {
    Lead l = new Lead(
      RecordTypeId = rt('SCO'),
      LastName = 'Lead 12121 ' + marca,
      Company = 'Empresa 12121 ' + marca,
      LeadSource = 'Indicacao',
      Status = 'Em nutrição',
      OwnerId = ownerId,
      SCO_BDR_Responsavel__c = bdrResponsavelId,
      SCO_Motivo_Nutricao__c = 'Sem timing',
      SCO_Data_Retomada__c = Date.today().addDays(1)
    );
    insert l;
    return l;
  }

  // T1. BDR: "Em contato" -> "Em nutrição" com "Sem orçamento no momento" e retomada em +60 dias salva.
  @IsTest
  static void t1BdrNutricaoSemOrcamentoSalva() {
    User b = persona('t1');
    Lead l = leadDoBdr(b, 'T1', 'Em contato');

    Test.startTest();
    String erro = erroComo(
      b,
      new Lead(
        Id = l.Id,
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Sem orçamento no momento',
        SCO_Data_Retomada__c = Date.today().addDays(60)
      )
    );
    Test.stopTest();

    Assert.isNull(erro, 'Nutrição com motivo v4 e data futura deve salvar.');
    Lead depois = recarregar(l.Id);
    Assert.areEqual('Em nutrição', depois.Status, 'Status');
    Assert.areEqual('Sem orçamento no momento', depois.SCO_Motivo_Nutricao__c, 'Motivo v4 gravado');
  }

  // T2. BDR: "Desqualificado" sem motivo é recusado com a mensagem mantida.
  @IsTest
  static void t2BdrDesqualificadoSemMotivoRecusa() {
    User b = persona('t2');
    Lead l = leadDoBdr(b, 'T2', 'Em contato');

    Test.startTest();
    String erro = erroComo(b, new Lead(Id = l.Id, Status = 'Desqualificado'));
    Test.stopTest();

    assertErro(erro, MSG_MOTIVO_DESQ);
    Assert.areEqual('Em contato', recarregar(l.Id).Status, 'Status não muda');
  }

  // T3. BDR: "Outros" sem observação recusa; com observação salva.
  @IsTest
  static void t3BdrOutrosExigeObservacao() {
    User b = persona('t3');
    Lead l = leadDoBdr(b, 'T3', 'Em contato');
    Lead desq = new Lead(Id = l.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Outros');

    Test.startTest();
    String semObs = erroComo(b, desq);
    desq.SCO_Observacao_Desqualificacao__c = 'Cliente pediu para encerrar o processo.';
    String comObs = erroComo(b, desq);
    Test.stopTest();

    assertErro(semObs, MSG_OBS_OUTROS);
    Assert.isNull(comObs, 'Com observação deve salvar.');
    Assert.areEqual('Desqualificado', recarregar(l.Id).Status, 'Status gravado');
  }

  // T4. BDR: "Fora do perfil" sem observação salva (observação opcional fora de "Outros").
  @IsTest
  static void t4BdrForaDoPerfilSemObservacaoSalva() {
    User b = persona('t4');
    Lead l = leadDoBdr(b, 'T4', 'Em contato');

    Test.startTest();
    String erro = erroComo(
      b,
      new Lead(Id = l.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Fora do perfil')
    );
    Test.stopTest();

    Assert.isNull(erro, 'Observação é opcional fora de Outros.');
    Lead depois = recarregar(l.Id);
    Assert.areEqual('Fora do perfil', depois.SCO_Motivo_Desqualificacao__c, 'Motivo gravado');
    Assert.isNull(depois.SCO_Observacao_Desqualificacao__c, 'Sem observação');
  }

  // T5. Regressão: reunião realizada -> "Em nutrição" sem motivo de reunião sem avanço bloqueia.
  @IsTest
  static void t5BdrReuniaoRealizadaParaNutricaoBloqueia() {
    User b = persona('t5');
    Lead l = leadDoBdr(b, 'T5', 'Em contato');
    System.runAs(b) {
      update new Lead(Id = l.Id, SCO_Data_Reuniao_Realizada__c = Date.today().addDays(-1));
    }

    Test.startTest();
    String erro = erroComo(
      b,
      new Lead(
        Id = l.Id,
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Sem orçamento no momento',
        SCO_Data_Retomada__c = Date.today().addDays(30)
      )
    );
    Test.stopTest();

    assertErro(erro, MSG_REUNIAO_SEM_AVANCO);
    Assert.areEqual('Em contato', recarregar(l.Id).Status, 'Status não muda');
  }

  // T6. "Desqualificado" + "Solicitou não ser contatado" marca Email Opt Out (transição e criação).
  @IsTest
  static void t6SolicitouNaoSerContatadoMarcaOptOut() {
    User b = persona('t6');
    Lead l = leadDoBdr(b, 'T6', 'Em contato');
    Lead criadoDesq = new Lead(
      RecordTypeId = rt('SCO'),
      LastName = 'Lead 12121 T6 criacao',
      Company = 'Empresa 12121 T6 criacao',
      LeadSource = 'Indicacao',
      Status = 'Desqualificado',
      SCO_Motivo_Desqualificacao__c = 'Solicitou não ser contatado'
    );

    Test.startTest();
    String erro = erroComo(
      b,
      new Lead(Id = l.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Solicitou não ser contatado')
    );
    System.runAs(b) {
      insert criadoDesq;
    }
    Test.stopTest();

    Assert.isNull(erro, 'Desqualificação deve salvar.');
    Assert.isTrue(optOut(l.Id), 'Transição para Desqualificado deve marcar o opt-out.');
    Assert.isTrue(optOut(criadoDesq.Id), 'Criação já desqualificada deve marcar o opt-out.');
  }

  // T7. O BDR desmarca o opt-out sem mudar status nem motivo: continua desmarcado.
  @IsTest
  static void t7BdrDesmarcaOptOutNaoRemarca() {
    User b = persona('t7');
    Lead l = leadDoBdr(b, 'T7', 'Em contato');
    System.runAs(b) {
      update new Lead(Id = l.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Solicitou não ser contatado');
    }
    Assert.isTrue(optOut(l.Id), 'Pré-condição: opt-out marcado.');

    Test.startTest();
    String erro = erroComo(b, new Lead(Id = l.Id, HasOptedOutOfEmail = false));
    String erro2 = erroComo(b, new Lead(Id = l.Id, SCO_Observacao_Desqualificacao__c = 'Ajuste posterior.'));
    Test.stopTest();

    Assert.isNull(erro, 'O BDR pode desmarcar o opt-out.');
    Assert.isNull(erro2, 'Edição sem mudar status nem motivo salva.');
    Assert.isFalse(optOut(l.Id), 'O sistema nunca remarca sozinho sem nova transição.');
  }

  // T8. Conversão: o Contato herda Email Opt Out pelo mapeamento nativo.
  @IsTest
  static void t8ConversaoLevaOptOutAoContato() {
    User b = persona('t8');
    Lead l = leadDoBdr(b, 'T8', 'Em contato');
    System.runAs(b) {
      update new Lead(Id = l.Id, HasOptedOutOfEmail = true);
    }

    Test.startTest();
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(l.Id);
    lc.setConvertedStatus('Convertido');
    lc.setDoNotCreateOpportunity(true);
    Database.LeadConvertResult r = Database.convertLead(lc);
    Test.stopTest();

    Assert.isTrue(r.isSuccess(), String.valueOf(r.getErrors()));
    Contact c = [SELECT HasOptedOutOfEmail FROM Contact WHERE Id = :r.getContactId()];
    Assert.isTrue(c.HasOptedOutOfEmail, 'O Contato deve herdar o Email Opt Out.');
  }

  // T9. Lead em "Em contato" recebendo Motivo da nutrição é recusado.
  @IsTest
  static void t9MotivoNutricaoForaDoStatusRecusa() {
    User b = persona('t9');
    Lead l = leadDoBdr(b, 'T9', 'Em contato');
    String naCriacao;

    Test.startTest();
    String erro = erroComo(b, new Lead(Id = l.Id, SCO_Motivo_Nutricao__c = 'Sem retorno'));
    System.runAs(b) {
      try {
        insert new Lead(
          RecordTypeId = rt('SCO'),
          LastName = 'Lead 12121 T9 criacao',
          Company = 'Empresa 12121 T9 criacao',
          LeadSource = 'Indicacao',
          Status = 'Em contato',
          SCO_Motivo_Nutricao__c = 'Sem retorno'
        );
      } catch (DmlException e) {
        naCriacao = e.getMessage();
      }
    }
    Test.stopTest();

    assertErro(erro, MSG_NUTRICAO_SO_EM_NUTRICAO);
    assertErro(naCriacao, MSG_NUTRICAO_SO_EM_NUTRICAO);
    Assert.isNull(recarregar(l.Id).SCO_Motivo_Nutricao__c, 'Motivo não gravado');
  }

  // T10. Lead em "Em contato" recebendo Motivo da desqualificação é recusado.
  @IsTest
  static void t10MotivoDesqualificacaoForaDoStatusRecusa() {
    User b = persona('t10');
    Lead l = leadDoBdr(b, 'T10', 'Em contato');

    Test.startTest();
    String erro = erroComo(b, new Lead(Id = l.Id, SCO_Motivo_Desqualificacao__c = 'Fora do perfil'));
    Test.stopTest();

    assertErro(erro, MSG_DESQ_SO_DESQUALIFICADO);
    Assert.isNull(recarregar(l.Id).SCO_Motivo_Desqualificacao__c, 'Motivo não gravado');
  }

  // T11. Nutrição -> "Em contato": o motivo permanece (não limpa); apagar o valor é permitido.
  @IsTest
  static void t11SairDaNutricaoMantemMotivoEApagarPermitido() {
    User b = persona('t11');
    Lead l = leadDoBdr(b, 'T11', 'Em contato');
    System.runAs(b) {
      update new Lead(
        Id = l.Id,
        Status = 'Em nutrição',
        SCO_Motivo_Nutricao__c = 'Já tem fornecedor com contrato vigente',
        SCO_Data_Retomada__c = Date.today().addDays(20)
      );
    }

    Test.startTest();
    String volta = erroComo(b, new Lead(Id = l.Id, Status = 'Em contato'));
    String edicao = erroComo(b, new Lead(Id = l.Id, Description = 'Retomou o contato.'));
    Lead antesDeApagar = recarregar(l.Id);
    String apagar = erroComo(b, new Lead(Id = l.Id, SCO_Motivo_Nutricao__c = null));
    Test.stopTest();

    Assert.isNull(volta, 'Voltar para Em contato salva.');
    Assert.isNull(edicao, 'Editar outro campo com motivo antigo salva.');
    Assert.areEqual(
      'Já tem fornecedor com contrato vigente',
      antesDeApagar.SCO_Motivo_Nutricao__c,
      'O motivo não pode ser limpo automaticamente.'
    );
    Assert.isNull(apagar, 'Apagar o valor é permitido.');
    Assert.isNull(recarregar(l.Id).SCO_Motivo_Nutricao__c, 'Valor apagado');
  }

  // T12. Subflow SCO_Lead_Criar_Tarefa_Retomada: dono, idempotência, elegibilidade e BDR inativo.
  @IsTest
  static void t12SubflowCriaTarefaRetomada() {
    User b = persona('t12a');
    User dono = persona('t12b');
    User inativo = persona('t12c');
    Lead comBdr = leadEmNutricaoAmanha('T12 com BDR', dono.Id, b.Id);
    Lead semBdr = leadEmNutricaoAmanha('T12 sem BDR', dono.Id, null);
    Lead foraNutricao = leadEmNutricaoAmanha('T12 fora', dono.Id, b.Id);
    update new Lead(Id = foraNutricao.Id, Status = 'Em contato');
    Lead bdrInativo = leadEmNutricaoAmanha('T12 inativo', dono.Id, inativo.Id);
    System.runAs(new User(Id = UserInfo.getUserId())) {
      update new User(Id = inativo.Id, IsActive = false);
    }
    Date amanha = Date.today().addDays(1);

    Test.startTest();
    rodarSubflowRetomada(comBdr.Id, amanha);
    rodarSubflowRetomada(comBdr.Id, amanha); // idempotência
    rodarSubflowRetomada(semBdr.Id, amanha);
    rodarSubflowRetomada(foraNutricao.Id, amanha);
    rodarSubflowRetomada(bdrInativo.Id, amanha);
    rodarSubflowRetomada(semBdr.Id, Date.today()); // data de referência diferente da retomada
    Test.stopTest();

    List<Task> tComBdr = tarefasRetomada(comBdr.Id);
    Assert.areEqual(1, tComBdr.size(), 'Uma tarefa só, mesmo com duas execuções.');
    Assert.areEqual(b.Id, tComBdr[0].OwnerId, 'Dono = BDR responsável ativo.');
    Assert.areEqual(amanha, tComBdr[0].ActivityDate, 'Vence na data de retomada.');
    Assert.areEqual(
      'Lead em nutrição. Motivo: Sem timing / não é prioridade agora',
      tComBdr[0].Description,
      'Descrição com o rótulo do motivo.'
    );
    List<Task> tSemBdr = tarefasRetomada(semBdr.Id);
    Assert.areEqual(1, tSemBdr.size(), 'Sem BDR: uma tarefa.');
    Assert.areEqual(dono.Id, tSemBdr[0].OwnerId, 'Sem BDR: dono do Lead.');
    Assert.areEqual(0, tarefasRetomada(foraNutricao.Id).size(), 'Fora de nutrição: nenhuma tarefa.');
    List<Task> tInativo = tarefasRetomada(bdrInativo.Id);
    Assert.areEqual(1, tInativo.size(), 'BDR inativo: uma tarefa.');
    Assert.areEqual(dono.Id, tInativo[0].OwnerId, 'BDR inativo: dono do Lead.');
  }

  // T12b. Lead em fila e sem BDR: nenhuma tarefa.
  @IsTest
  static void t12bLeadEmFilaSemBdrNaoCriaTarefa() {
    Group fila = new Group(Name = 'Fila 12121 Teste', Type = 'Queue');
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
    }
    Lead l = leadEmNutricaoAmanha('T12b fila', fila.Id, null);

    Test.startTest();
    rodarSubflowRetomada(l.Id, Date.today().addDays(1));
    Test.stopTest();

    Assert.areEqual(0, tarefasRetomada(l.Id).size(), 'Dono fila e sem BDR: nenhuma tarefa.');
  }

  // T13. Volume: 200 Leads SCO para "Em nutrição" com data futura, sem erro de limite.
  @IsTest
  static void t13VolumeNutricao() {
    User b = persona('t13');
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 200; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rt('SCO'),
          LastName = 'Lead 12121 vol ' + i,
          Company = 'Empresa 12121 vol ' + i,
          LeadSource = 'Indicacao',
          Status = 'Em contato'
        )
      );
    }
    System.runAs(b) {
      insert leads;
    }
    for (Lead l : leads) {
      l.Status = 'Em nutrição';
      l.SCO_Motivo_Nutricao__c = 'Sem retorno';
      l.SCO_Data_Retomada__c = Date.today().addDays(45);
    }

    Test.startTest();
    System.runAs(b) {
      update leads;
    }
    Test.stopTest();

    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Status = 'Em nutrição' AND SCO_Data_Retomada__c != null],
      '200 Leads em nutrição.'
    );
  }

  // T14. Lead SOL desqualificado não recebe opt-out, mesmo com o motivo SCO preenchido.
  @IsTest
  static void t14LeadSolNaoRecebeOptOut() {
    Lead sol = new Lead(
      RecordTypeId = rt('SOL'),
      LastName = 'Lead SOL 12121',
      Company = 'Empresa SOL 12121',
      Status = 'Recebido - MQL',
      CNPJ__c = CNPJ_SOL
    );
    insert sol;

    Test.startTest();
    String erro = erroAoAtualizar(
      new Lead(
        Id = sol.Id,
        Status = 'Desqualificado',
        SOL_Motivo_Desqualificacao__c = 'Negócio perdido'
      )
    );
    Test.stopTest();

    Assert.isNull(erro, 'SOL desqualifica com as regras dela. Erro: ' + erro);
    Assert.areEqual('Desqualificado', recarregar(sol.Id).Status, 'Status SOL');
    Assert.isFalse(optOut(sol.Id), 'Opt-out é só da S Company.');
  }
}
