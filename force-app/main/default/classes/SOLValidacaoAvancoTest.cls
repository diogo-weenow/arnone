/**
 * CLICKUP-9419 — Card 08 — Testes da validação de avanço (reunião + procuração).
 *
 * O Flow before-save SOL_Validar_Avanco_Reuniao_Procuracao está ATIVO e bloqueia,
 * com Custom Error, o avanço de etapa de um Lead da Arnone Soluções (Recuperação
 * Tributária ou ART 360) quando faltam evidências:
 *  - Portão 1 — entrar em "Procuração Solicitada": reunião comercial REALIZADA +
 *    solicitação válida (Status + SOL_Status_Procuracao__c = "Solicitada" + data).
 *  - Portão 2 — entrar em "Apto para Conversão": reunião realizada + procuração
 *    "Recebida" com data + ao menos um arquivo no Lead.
 *  - Conversão (IsConverted): procuração "Recebida" com data + arquivo (a reunião
 *    já é exigida ao entrar em "Apto para Conversão"; durante Database.convertLead
 *    as atividades do Lead ficam indisponíveis para query — limitação de
 *    plataforma, vale p/ Flow e Apex).
 *
 * Não bloqueia: outras BUs, atualização sem avanço, desqualificação/opt-out,
 * retorno de etapa.
 */
@IsTest
private class SOLValidacaoAvancoTest {
  private static final String CNPJ = '11222333000181';
  private static final String CAPTACAO = 'Captação - Contato';
  private static final String SQL_STATUS = 'Reunião Agendada - SQL';
  private static final String PROC_SOLICITADA = 'Procuração Solicitada';
  private static final String APTO = 'Apto para Conversão';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static Id rtSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Lead novoLead(String produto) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = 'V ' + Math.abs(Crypto.getRandomInteger()),
      Company = 'C',
      Status = CAPTACAO,
      CNPJ__c = CNPJ,
      SOL_Produto_Interesse__c = produto
    );
    insert l;
    return l;
  }

  private static void reuniao(Id leadId, String status, String resultado) {
    Task t = new Task(
      Subject = 'x',
      WhoId = leadId,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;
    if (status != 'Open') {
      Task upd = new Task(Id = t.Id, Status = status);
      if (resultado != null) {
        upd.SOL_Resultado_Reuniao__c = resultado;
      }
      update upd;
    }
  }

  private static void reuniaoRealizada(Id leadId) {
    reuniao(leadId, 'Completed', 'Realizada');
  }

  private static void arquivo(Id leadId) {
    ContentVersion cv = new ContentVersion(
      Title = 'proc',
      PathOnClient = 'proc.txt',
      VersionData = Blob.valueOf('doc')
    );
    insert cv;
    Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]
      .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = docId,
      LinkedEntityId = leadId,
      ShareType = 'V'
    );
  }

  private static Lead patchSolicitacao() {
    return new Lead(
      Status = PROC_SOLICITADA,
      SOL_Status_Procuracao__c = 'Solicitada',
      SOL_Data_Solicitacao_Procuracao__c = Date.today()
    );
  }

  /** Aplica `patch` e devolve null se passou, ou o texto do Custom Error. */
  private static String tentar(Id leadId, Lead patch) {
    Savepoint sp = Database.setSavepoint();
    try {
      patch.Id = leadId;
      update patch;
      Database.rollback(sp);
      return null;
    } catch (DmlException e) {
      Database.rollback(sp);
      return e.getDmlMessage(0);
    }
  }

  private static String tentarConverter(Id leadId) {
    Savepoint sp = Database.setSavepoint();
    Database.LeadConvert lc = new Database.LeadConvert();
    lc.setLeadId(leadId);
    lc.setDoNotCreateOpportunity(true);
    lc.setConvertedStatus(
      [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1].MasterLabel
    );
    try {
      Database.convertLead(lc);
      Database.rollback(sp);
      return null;
    } catch (Exception e) {
      Database.rollback(sp);
      return e.getMessage();
    }
  }

  // ============================================================ PORTÃO 1

  @IsTest
  static void portao1_reuniaoRealizadaPermiteSolicitarProcuracao_RecTrib() {
    Lead l = novoLead('Recuperação Tributária');
    reuniaoRealizada(l.Id);
    Test.startTest();
    String erro = tentar(l.Id, patchSolicitacao());
    Test.stopTest();
    System.assertEquals(null, erro, 'Reunião realizada + solicitação válida deve passar. ' + erro);
  }

  @IsTest
  static void portao1_reuniaoRealizadaPermiteSolicitarProcuracao_ART360() {
    Lead l = novoLead('ART 360');
    reuniaoRealizada(l.Id);
    Test.startTest();
    System.assertEquals(null, tentar(l.Id, patchSolicitacao()), 'ART 360 também exige e passa.');
    Test.stopTest();
  }

  @IsTest
  static void portao1_semReuniaoBloqueia() {
    Lead l = novoLead('Recuperação Tributária');
    Test.startTest();
    String erro = tentar(l.Id, patchSolicitacao());
    Test.stopTest();
    System.assert(erro != null && erro.contains('reunião'), 'Sem reunião: bloqueia. ' + erro);
  }

  @IsTest
  static void portao1_reuniaoApenasAbertaBloqueia() {
    Lead l = novoLead('ART 360');
    reuniao(l.Id, 'Open', null);
    Test.startTest();
    String erro = tentar(l.Id, patchSolicitacao());
    Test.stopTest();
    System.assert(erro != null && erro.contains('reunião'), 'Reunião só aberta não conta. ' + erro);
  }

  @IsTest
  static void portao1_reuniaoEncerradaSemResultadoBloqueia() {
    Lead l = novoLead('ART 360');
    reuniao(l.Id, 'Completed', null);
    Test.startTest();
    String erro = tentar(l.Id, patchSolicitacao());
    Test.stopTest();
    System.assert(erro != null && erro.contains('reunião'), 'Encerrada sem resultado não conta. ' + erro);
  }

  @IsTest
  static void portao1_reuniaoCanceladaBloqueia() {
    Lead l = novoLead('Recuperação Tributária');
    Task t = new Task(
      Subject = 'x',
      WhoId = l.Id,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;
    update new Task(
      Id = t.Id,
      Status = 'Cancelada',
      SOL_Motivo_Cancelamento__c = 'Opt-out',
      SOL_Resultado_Reuniao__c = 'Realizada'
    );
    Test.startTest();
    String erro = tentar(l.Id, patchSolicitacao());
    Test.stopTest();
    System.assert(erro != null && erro.contains('reunião'), 'Task cancelada não conta. ' + erro);
  }

  @IsTest
  static void portao1_reuniaoNaoCompareceuBloqueia() {
    Lead l = novoLead('ART 360');
    reuniao(l.Id, 'Completed', 'Não compareceu');
    Test.startTest();
    String erro = tentar(l.Id, patchSolicitacao());
    Test.stopTest();
    System.assert(erro != null && erro.contains('reunião'), '"Não compareceu" não conta. ' + erro);
  }

  @IsTest
  static void portao1_reuniaoRealizadaMasSolicitacaoIncompletaBloqueia() {
    Lead l = novoLead('Recuperação Tributária');
    reuniaoRealizada(l.Id);
    Test.startTest();
    // só o Status, sem SOL_Status_Procuracao__c nem a data
    String erro = tentar(l.Id, new Lead(Status = PROC_SOLICITADA));
    Test.stopTest();
    System.assert(erro != null && erro.contains('solicitação'), 'Solicitação incompleta: bloqueia. ' + erro);
  }

  @IsTest
  static void portao1_somenteProcuracaoSemReuniaoBloqueia() {
    Lead l = novoLead('ART 360');
    Test.startTest();
    String erro = tentar(l.Id, patchSolicitacao());
    Test.stopTest();
    System.assert(erro != null && erro.contains('reunião'), 'Só procuração, sem reunião: bloqueia. ' + erro);
  }

  // ============================================================ PORTÃO 2

  private static Lead leadComReuniaoESolicitacao(String produto) {
    Lead l = novoLead(produto);
    reuniaoRealizada(l.Id);
    update new Lead(
      Id = l.Id,
      Status = PROC_SOLICITADA,
      SOL_Status_Procuracao__c = 'Solicitada',
      SOL_Data_Solicitacao_Procuracao__c = Date.today()
    );
    return l;
  }

  @IsTest
  static void portao2_procuracaoNaoRecebidaBloqueia() {
    Lead l = leadComReuniaoESolicitacao('Recuperação Tributária');
    Test.startTest();
    String erro = tentar(l.Id, new Lead(Status = APTO));
    Test.stopTest();
    System.assert(erro != null && erro.contains('procuração'), 'Procuração não recebida: bloqueia. ' + erro);
  }

  @IsTest
  static void portao2_recebidaSemDataBloqueia() {
    Lead l = leadComReuniaoESolicitacao('ART 360');
    update new Lead(Id = l.Id, SOL_Status_Procuracao__c = 'Recebida');
    Test.startTest();
    String erro = tentar(l.Id, new Lead(Status = APTO));
    Test.stopTest();
    System.assert(erro != null && erro.contains('procuração'), 'Recebida sem data: bloqueia. ' + erro);
  }

  @IsTest
  static void portao2_recebidaComDataSemArquivoBloqueia() {
    Lead l = leadComReuniaoESolicitacao('Recuperação Tributária');
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    Test.startTest();
    String erro = tentar(l.Id, new Lead(Status = APTO));
    Test.stopTest();
    System.assert(erro != null && erro.contains('documento'), 'Sem arquivo: bloqueia. ' + erro);
  }

  @IsTest
  static void portao2_reuniaoProcuracaoArquivoPermiteApto() {
    Lead l = leadComReuniaoESolicitacao('ART 360');
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    arquivo(l.Id);
    Test.startTest();
    String erro = tentar(l.Id, new Lead(Status = APTO));
    Test.stopTest();
    System.assertEquals(null, erro, 'Reunião + procuração + arquivo: permite Apto. ' + erro);
  }

  @IsTest
  static void portao2_saltoDiretoDeEtapaBloqueia() {
    Lead l = novoLead('Recuperação Tributária');
    Test.startTest();
    String erro = tentar(l.Id, new Lead(Status = APTO));
    Test.stopTest();
    System.assert(erro != null, 'Salto Captação -> Apto sem nada: bloqueia. ' + erro);
  }

  @IsTest
  static void portao2_qualificadoManualSemReuniaoBloqueia() {
    Lead l = novoLead('ART 360');
    Test.startTest();
    // A alteração manual para "Qualificado" também passa pelo Portão 2.
    String erro = tentar(l.Id, new Lead(Status = 'Qualificado'));
    Test.stopTest();
    System.assert(erro != null && erro.contains('reunião'), '"Qualificado" manual sem reunião: bloqueia. ' + erro);
  }

  // ============================================================ CONVERSÃO

  @IsTest
  static void conversao_semRequisitosBloqueia() {
    Lead l = novoLead('ART 360');
    Test.startTest();
    String erro = tentarConverter(l.Id);
    Test.stopTest();
    System.assert(erro != null, 'Conversão sem requisitos: bloqueia. ' + erro);
  }

  @IsTest
  static void conversao_semArquivoBloqueia() {
    Lead l = leadComReuniaoESolicitacao('Recuperação Tributária');
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    Test.startTest();
    String erro = tentarConverter(l.Id);
    Test.stopTest();
    System.assert(erro != null && erro.contains('documento'), 'Conversão sem arquivo: bloqueia. ' + erro);
  }

  @IsTest
  static void conversao_comProcuracaoEArquivoMasSemReuniaoBloqueia() {
    // O bloqueador do PR: procuração marcada como recebida + arquivo, SEM
    // nenhuma reunião realizada (SOL_Data_Reuniao_Realizada__c vazio).
    Lead l = novoLead('Recuperação Tributária');
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    arquivo(l.Id);
    System.assertEquals(
      null,
      [SELECT SOL_Data_Reuniao_Realizada__c FROM Lead WHERE Id = :l.Id].SOL_Data_Reuniao_Realizada__c
    );

    Test.startTest();
    String erro = tentarConverter(l.Id);
    Test.stopTest();

    System.assert(
      erro != null && erro.contains('reunião'),
      'Conversão com procuração + arquivo mas SEM reunião: bloqueia. ' + erro
    );
  }

  @IsTest
  static void conversao_comReuniaoProcuracaoEArquivoConverte() {
    Lead l = leadComReuniaoESolicitacao('Recuperação Tributária');
    update new Lead(
      Id = l.Id,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    arquivo(l.Id);
    update new Lead(Id = l.Id, Status = APTO);
    System.assertNotEquals(
      null,
      [SELECT SOL_Data_Reuniao_Realizada__c FROM Lead WHERE Id = :l.Id].SOL_Data_Reuniao_Realizada__c,
      'A reunião ficou consolidada no Lead.'
    );
    Test.startTest();
    String erro = tentarConverter(l.Id);
    Test.stopTest();
    System.assertEquals(null, erro, 'Com todos os requisitos: converte. ' + erro);
  }

  // ============================================================ PERMITIDOS

  /**
   * Desqualificar não é avanço de etapa: a validação de reunião/procuração do
   * CLICKUP-9419 não se mete nisso. Desde o D2 da homologação E2E o motivo da
   * desqualificação é obrigatório (VR SOL_Desqualificacao_Coerente), então o
   * cenário legítimo passou a ser "desqualificar COM motivo" — e este teste
   * segue provando que quem não barra é a validação de avanço.
   */
  @IsTest
  static void desqualificacaoComMotivoSemprePermitida() {
    Lead l = novoLead('Recuperação Tributária');
    Test.startTest();
    System.assertEquals(
      null,
      tentar(
        l.Id,
        new Lead(
          Status = 'Desqualificado',
          SOL_Motivo_Desqualificacao__c = 'Negócio perdido'
        )
      ),
      'Desqualificar com motivo não passa pela validação de avanço.'
    );
    Test.stopTest();
  }

  /** O motivo é obrigatório para desqualificar — quem barra é a VR do D2. */
  @IsTest
  static void desqualificacaoSemMotivoEhBloqueada() {
    Lead l = novoLead('Recuperação Tributária');
    Test.startTest();
    String erro = tentar(l.Id, new Lead(Status = 'Desqualificado'));
    Test.stopTest();
    System.assertNotEquals(null, erro, 'Desqualificar sem motivo tem de falhar.');
  }

  @IsTest
  static void optOutPermiteDesqualificar() {
    Lead l = novoLead('ART 360');
    Test.startTest();
    System.assertEquals(
      null,
      tentar(l.Id, new Lead(Status = 'Desqualificado', SOL_Opt_Out__c = true, SOL_Motivo_Desqualificacao__c = 'Opt-out')),
      'Opt-out permitido.'
    );
    Test.stopTest();
  }

  @IsTest
  static void retornoDeEtapaPermitido() {
    Lead l = novoLead('ART 360');
    update new Lead(Id = l.Id, Status = SQL_STATUS);
    Test.startTest();
    System.assertEquals(null, tentar(l.Id, new Lead(Status = CAPTACAO)), 'Retorno de etapa permitido.');
    Test.stopTest();
  }

  @IsTest
  static void atualizacaoSemAvancoPermitida() {
    Lead l = novoLead('Recuperação Tributária');
    Test.startTest();
    System.assertEquals(null, tentar(l.Id, new Lead(Description = 'edição qualquer')), 'Update sem avanço não bloqueia.');
    Test.stopTest();
  }

  @IsTest
  static void outraBUIntacta() {
    Lead o = new Lead(LastName = 'OutraBU', Company = 'C', Status = 'Novo');
    insert o;
    Test.startTest();
    System.assertEquals(null, tentar(o.Id, new Lead(Status = 'Em Qualificação')), 'Outra BU não é bloqueada.');
    Test.stopTest();
  }

  @IsTest
  static void produtoForaDoEscopoNaoEhBloqueado() {
    Lead l = novoLead(null); // produto em branco
    Test.startTest();
    System.assertEquals(null, tentar(l.Id, new Lead(Status = PROC_SOLICITADA)), 'Produto fora do escopo: não valida.');
    Test.stopTest();
  }

  // ============================================================ VENDEDOR COMERCIAL

  @IsTest
  static void vendedorComercialSofreAValidacao() {
    Profile p;
    for (Profile pr : [SELECT Id, Name FROM Profile WHERE UserType = 'Standard']) {
      if (pr.Name == 'Standard User') {
        p = pr;
      }
    }
    if (p == null) {
      p = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
    }
    User u = new User(
      FirstName = 'RR',
      LastName = 'Comercial Val',
      Alias = 'rrcval',
      Email = 'rr.cval@arnone.invalid',
      Username = 'rr.cval.' + Math.abs(Crypto.getRandomInteger()) + '@arnone.clickup9419.test.invalid',
      ProfileId = p.Id,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
      insert new PermissionSetAssignment(
        AssigneeId = u.Id,
        PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id
      );
    }

    Lead l = novoLead('Recuperação Tributária');
    update new Lead(Id = l.Id, OwnerId = u.Id); // o vendedor opera no próprio Lead

    Test.startTest();
    System.runAs(u) {
      // sem reunião → bloqueado, mesmo para o vendedor comercial
      String erro = tentar(l.Id, patchSolicitacao());
      System.assert(erro != null && erro.contains('reunião'), 'Vendedor comercial também é validado. ' + erro);
    }
    reuniaoRealizada(l.Id);
    System.runAs(u) {
      System.assertEquals(null, tentar(l.Id, patchSolicitacao()), 'Com reunião, o vendedor comercial passa.');
    }
    Test.stopTest();
  }

  // ============================================================ LOTE

  @IsTest
  static void processamentoEmLote() {
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 20; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rtSOL(),
          LastName = 'Lote ' + i,
          Company = 'C',
          Status = CAPTACAO,
          CNPJ__c = CNPJ,
          SOL_Produto_Interesse__c = (Math.mod(i, 2) == 0 ? 'Recuperação Tributária' : 'ART 360')
        )
      );
    }
    insert leads;

    // Metade recebe reunião realizada.
    List<Task> ts = new List<Task>();
    for (Integer i = 0; i < leads.size(); i++) {
      if (Math.mod(i, 2) == 0) {
        ts.add(
          new Task(
            Subject = 'x',
            WhoId = leads[i].Id,
            OwnerId = UserInfo.getUserId(),
            Status = 'Open',
            ActivityDate = Date.today(),
            SOL_Tipo_Tarefa__c = 'Reunião comercial'
          )
        );
      }
    }
    insert ts;
    List<Task> fecha = new List<Task>();
    for (Task t : ts) {
      fecha.add(new Task(Id = t.Id, Status = 'Completed', SOL_Resultado_Reuniao__c = 'Realizada'));
    }
    update fecha;

    List<Lead> patches = new List<Lead>();
    for (Lead l : leads) {
      patches.add(
        new Lead(
          Id = l.Id,
          Status = PROC_SOLICITADA,
          SOL_Status_Procuracao__c = 'Solicitada',
          SOL_Data_Solicitacao_Procuracao__c = Date.today()
        )
      );
    }

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Database.SaveResult[] rs = Database.update(patches, false);
    Integer soql = Limits.getQueries() - q0;
    Test.stopTest();

    Integer ok = 0;
    Integer bloq = 0;
    for (Database.SaveResult sr : rs) {
      if (sr.isSuccess()) {
        ok++;
      } else {
        bloq++;
      }
    }
    System.assertEquals(10, ok, 'Os 10 com reunião realizada passam.');
    System.assertEquals(10, bloq, 'Os 10 sem reunião são bloqueados.');
    System.assert(soql < 20, 'Get Records bulkificado: ' + soql + ' SOQL para 20 leads.');
  }
}
