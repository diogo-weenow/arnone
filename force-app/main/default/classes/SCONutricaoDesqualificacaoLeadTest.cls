/**
 * CLICKUP-11813 — Nutrição, desqualificação e reunião sem avanço no Lead da S Company.
 * Cobre as VRs SCO_Nutricao_Exige_Motivo_E_Retomada, SCO_Nutricao_Exige_Data_Retomada_Futura,
 * SCO_Desqualificado_Exige_Motivo e SCO_Reuniao_Sem_Avanco_Exige_Motivo, o reengajamento
 * (volta para "Em contato" sem limpar o histórico) e o isolamento das outras unidades.
 */
@IsTest
private class SCONutricaoDesqualificacaoLeadTest {
  private static final String MSG_MOTIVO_NUTRICAO = 'Informe o motivo da nutrição.';
  private static final String MSG_DATA_RETOMADA = 'Informe a data de retomada.';
  private static final String MSG_MOTIVO_DESQ = 'Informe o motivo da desqualificação.';
  private static final String MSG_REUNIAO_SEM_AVANCO = 'Informe o motivo da reunião sem avanço.';
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

  // 4. "Desqualificado" exige motivo; observação é opcional, inclusive com "Outros".
  @IsTest
  static void desqualificadoExigeMotivoObservacaoOpcional() {
    Lead l = leadSco('Em contato', null);

    Test.startTest();
    String semMotivo = erroAoAtualizar(new Lead(Id = l.Id, Status = 'Desqualificado'));
    String outrosSemObs = erroAoAtualizar(
      new Lead(Id = l.Id, Status = 'Desqualificado', SCO_Motivo_Desqualificacao__c = 'Outros')
    );
    Test.stopTest();

    assertErro(semMotivo, MSG_MOTIVO_DESQ);
    System.assertEquals(null, outrosSemObs, 'Observação nunca é obrigatória.');
    Lead depois = recarregar(l.Id);
    System.assertEquals('Desqualificado', depois.Status);
    System.assertEquals(null, depois.SCO_Observacao_Desqualificacao__c);
  }

  // 5a. Reunião realizada -> "Em nutrição" exige motivo da reunião sem avanço.
  @IsTest
  static void reuniaoRealizadaParaNutricaoExigeMotivo() {
    Lead l = leadSco('Em contato', Date.today().addDays(-2));
    Lead nutricao = new Lead(
      Id = l.Id,
      Status = 'Em nutrição',
      SCO_Motivo_Nutricao__c = 'Sem interesse no momento',
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
}
