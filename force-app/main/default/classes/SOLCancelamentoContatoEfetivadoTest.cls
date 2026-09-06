/**
 * CLICKUP-9449 — Testes da TERCEIRA porta do contato efetivado: a alteração do
 * próprio `Lead.SOL_Contato_Efetivado__c` para verdadeiro.
 *
 * Até o CLICKUP-9448 o cancelamento das tarefas pendentes só acontecia pelas
 * TASKS — ligação com "Atendeu" (9417), checkbox de resposta no e-mail (9447) e
 * no WhatsApp (9448). Quem marcasse o flag direto no Lead (tela, API,
 * importação, outra automação) deixava as tarefas abertas. O Flow
 * `SOL_Cancelar_Tarefas_Apos_Contato_Efetivado` fecha esse buraco chamando o
 * MESMO serviço — sem serviço, campo, status ou motivo novo.
 *
 * Classe dedicada de propósito: `SOLContatoEfetivadoTest` já passou de 2.900
 * linhas com os cards 9417/9437/9447/9448.
 *
 * CONCORRÊNCIA — paralelismo real não é simulável em Apex, e nenhum teste aqui
 * finge prová-lo. A garantia vem do `FOR UPDATE` que o serviço toma no Lead e
 * nas Tasks: duas transações sobre o mesmo Lead são serializadas pelo banco, e
 * a segunda encontra o trabalho da primeira já commitado. O que estes testes
 * cobrem é o observável: idempotência, estados sequenciais e comportamento em
 * lote.
 */
@IsTest
private class SOLCancelamentoContatoEfetivadoTest {
  private static final String FILA_SINTETICA = 'RR_Canc_SOL_9449';
  private static final String CNPJ = '11222333000181';
  private static final String MOTIVO = 'Contato efetivado';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User vendedor(String tag) {
    return new User(
      FirstName = 'RR',
      LastName = 'Canc ' + tag,
      Alias = ('rc' + tag).left(8),
      Email = 'rr.canc' + tag + '@arnone.invalid',
      Username = 'rr.canc.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9449.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static Id filaId;

  private static void montarCenario(Integer qtd) {
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      vs.add(vendedor('v' + i));
    }
    System.runAs(contextoAtual()) {
      insert vs;
      Group fila = new Group(
        Name = 'RR Canc SOL 9449',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      filaId = fila.Id;
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : vs) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = u.Id));
      }
      insert gms;
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
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

  private static Lead novoLeadSOL(String nome, String produto) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = nome,
      Company = 'C',
      Status = statusLead(),
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
        IsConverted,
        SOL_Contato_Efetivado__c,
        SOL_Data_Contato_Efetivado__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  /** Tarefa de contato ABERTA no canal informado. */
  private static Task contatoAberto(Lead l, String canal) {
    Task t = new Task(
      Subject = canal + ' pendente',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Contato',
      SOL_Canal_Contato__c = canal,
      SOL_Dia_Cadencia__c = 2
    );
    insert t;
    return t;
  }

  /** Tarefa ABERTA que NÃO é de contato — tem de sobreviver ao cancelamento. */
  private static Task naoContatoAberto(Lead l) {
    Task t = new Task(
      Subject = 'Reunião comercial pendente',
      WhoId = l.Id,
      OwnerId = l.OwnerId,
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Reunião comercial'
    );
    insert t;
    return t;
  }

  private static Task lerTarefa(Id taskId) {
    return [
      SELECT
        Id,
        Subject,
        Status,
        IsClosed,
        SOL_Tipo_Tarefa__c,
        SOL_Canal_Contato__c,
        SOL_Resultado_Contato__c,
        SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE Id = :taskId
    ];
  }

  private static Integer abertasDeContato(Id leadId) {
    return [
      SELECT COUNT()
      FROM Task
      WHERE
        WhoId = :leadId
        AND SOL_Tipo_Tarefa__c = 'Contato'
        AND IsClosed = FALSE
    ];
  }

  /** Marca o flag DIRETO no Lead — a porta que este card cria. */
  private static void marcarDireto(Id leadId) {
    update new Lead(Id = leadId, SOL_Contato_Efetivado__c = true);
  }

  // ============================================ a porta nova: flag no Lead

  /**
   * (1), (2), (3) e (4) Marcar o flag direto no Lead cancela as abertas dos
   * TRÊS canais, com o motivo da automação existente, e não toca no que já
   * estava fechado nem no que não é tarefa de contato.
   */
  @IsTest
  static void flagDiretoNoLeadCancelaAsAbertasDosTresCanais() {
    montarCenario(2);
    Lead l = novoLeadSOL('S9449a', 'Recuperação Tributária');
    Task ligacao = contatoAberto(l, 'Ligação');
    Task email = contatoAberto(l, 'E-mail');
    Task whats = contatoAberto(l, 'WhatsApp');
    Task naoContato = naoContatoAberto(l);

    // Uma já concluída e uma já cancelada: histórico que não pode ser tocado.
    Task concluida = contatoAberto(l, 'Ligação');
    update new Task(
      Id = concluida.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Não atendeu'
    );
    Task jaCancelada = contatoAberto(l, 'E-mail');
    update new Task(
      Id = jaCancelada.Id,
      Status = 'Cancelada',
      SOL_Motivo_Cancelamento__c = 'Opt-out'
    );

    Test.startTest();
    marcarDireto(l.Id);
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Contato_Efetivado__c, 'O flag ficou marcado.');
    System.assertNotEquals(
      null,
      d.SOL_Data_Contato_Efetivado__c,
      'E a data foi gravada pelo serviço.'
    );

    for (Id alvo : new List<Id>{ ligacao.Id, email.Id, whats.Id }) {
      Task t = lerTarefa(alvo);
      System.assertEquals(
        'Cancelada',
        t.Status,
        'A pendente de ' + t.SOL_Canal_Contato__c + ' foi cancelada.'
      );
      System.assertEquals(
        MOTIVO,
        t.SOL_Motivo_Cancelamento__c,
        'Com o motivo "Contato efetivado".'
      );
    }

    Task depoisConcluida = lerTarefa(concluida.Id);
    System.assertEquals(
      'Completed',
      depoisConcluida.Status,
      'A tarefa já concluída permanece concluída.'
    );
    System.assertEquals(
      null,
      depoisConcluida.SOL_Motivo_Cancelamento__c,
      'E sem motivo de cancelamento.'
    );

    Task depoisCancelada = lerTarefa(jaCancelada.Id);
    System.assertEquals(
      'Opt-out',
      depoisCancelada.SOL_Motivo_Cancelamento__c,
      'A já cancelada mantém o motivo ORIGINAL: não é reescrita.'
    );

    System.assertEquals(
      'Open',
      lerTarefa(naoContato.Id).Status,
      'A tarefa que não é de contato continua aberta.'
    );
    System.assertEquals(0, abertasDeContato(l.Id), 'Nenhuma de contato pendente.');
  }

  /** (5) e (12) Reprocessar não duplica, não falha e não sobrescreve a data. */
  @IsTest
  static void reprocessarNaoDuplicaNemSobrescreveAData() {
    montarCenario(2);
    Lead l = novoLeadSOL('S9449b', 'Recuperação Tributária');
    Task pendente = contatoAberto(l, 'WhatsApp');

    marcarDireto(l.Id);
    Lead aposPrimeira = recarregar(l.Id);
    Datetime dataOriginal = aposPrimeira.SOL_Data_Contato_Efetivado__c;
    System.assertNotEquals(null, dataOriginal, 'Pré-condição: data gravada.');

    Test.startTest();
    // Segunda gravação do mesmo valor e reprocessamento direto pelo serviço.
    update new Lead(Id = l.Id, SOL_Contato_Efetivado__c = true);
    SOLDistribuicaoService.registrarContatoEfetivado(new List<Id>{ l.Id });
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Contato_Efetivado__c, 'Continua marcado.');
    System.assertEquals(
      dataOriginal,
      d.SOL_Data_Contato_Efetivado__c,
      'A data do PRIMEIRO contato efetivado não é sobrescrita.'
    );
    System.assertEquals(
      'Cancelada',
      lerTarefa(pendente.Id).Status,
      'A tarefa segue cancelada, uma única vez.'
    );
    System.assertEquals(0, abertasDeContato(l.Id), 'Nada pendente.');
  }

  // ==================================== as portas antigas seguem funcionando

  /** (6) A ligação com "Atendeu" continua funcionando com o Flow novo ativo. */
  @IsTest
  static void ligacaoComAtendeuContinuaFuncionando() {
    montarCenario(2);
    Lead l = novoLeadSOL('S9449c', 'Recuperação Tributária');
    Task ligacao = contatoAberto(l, 'Ligação');
    Task email = contatoAberto(l, 'E-mail');

    Test.startTest();
    update new Task(
      Id = ligacao.Id,
      Status = 'Completed',
      SOL_Resultado_Contato__c = 'Atendeu'
    );
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Contato_Efetivado__c, 'Lead sinalizado.');
    System.assertEquals(
      'Completed',
      lerTarefa(ligacao.Id).Status,
      'A ligação de origem continua concluída.'
    );
    System.assertEquals(
      'Cancelada',
      lerTarefa(email.Id).Status,
      'E a pendente do outro canal foi cancelada.'
    );
    System.assertEquals(0, abertasDeContato(l.Id), 'Nada pendente.');
  }

  /**
   * (7) E-mail e WhatsApp continuam funcionando SEM dupla atualização.
   *
   * Este teste fixa o mecanismo anti-recursão medido no card: o serviço cancela
   * as TAREFAS antes de gravar o LEAD, então a reentrada disparada pelo Flow de
   * Lead encontra o flag já marcado e as tarefas já fechadas, e não faz DML
   * nenhum. Na ordem inversa a mesma tarefa seria gravada duas vezes — medido
   * nesta org: 6 DML statements contra 5.
   */
  @IsTest
  static void mensagemNaoAtualizaTarefaDuasVezes() {
    montarCenario(2);
    Lead l = novoLeadSOL('S9449d', 'Recuperação Tributária');
    Task ligacao = contatoAberto(l, 'Ligação');
    Task whats = contatoAberto(l, 'WhatsApp');
    Task email = contatoAberto(l, 'E-mail');
    update new Task(
      Id = email.Id,
      Status = 'Completed',
      SOL_Resultado_Envio__c = 'Enviado'
    );

    Test.startTest();
    Integer dmlAntes = Limits.getDmlStatements();
    update new Task(Id = email.Id, SOL_Contato_Efetivado__c = true);
    Integer delta = Limits.getDmlStatements() - dmlAntes;
    Test.stopTest();

    System.assertEquals(
      true,
      recarregar(l.Id).SOL_Contato_Efetivado__c,
      'O Lead foi sinalizado pela resposta no e-mail.'
    );
    System.assertEquals(
      'Cancelada',
      lerTarefa(ligacao.Id).Status,
      'A ligação pendente foi cancelada.'
    );
    System.assertEquals(
      'Cancelada',
      lerTarefa(whats.Id).Status,
      'E o WhatsApp pendente também.'
    );
    System.assert(
      delta <= 5,
      'A reentrada pelo Flow de Lead não pode regravar as tarefas: com a ordem ' +
        'correta a transação usa 5 DML statements; 6 indicaria dupla ' +
        'atualização. Usou ' +
        delta
    );
  }

  /** (8) Duas efetivações do mesmo Lead no MESMO lote não geram erro. */
  @IsTest
  static void duasEfetivacoesDoMesmoLeadNoMesmoLote() {
    montarCenario(2);
    Lead l = novoLeadSOL('S9449e', 'Recuperação Tributária');
    Task ligacao = contatoAberto(l, 'Ligação');
    Task whats = contatoAberto(l, 'WhatsApp');
    Task email = contatoAberto(l, 'E-mail');
    update new Task(
      Id = email.Id,
      Status = 'Completed',
      SOL_Resultado_Envio__c = 'Enviado'
    );

    Test.startTest();
    // A ligação efetiva e o e-mail registra a resposta, no MESMO DML.
    update new List<Task>{
      new Task(
        Id = ligacao.Id,
        Status = 'Completed',
        SOL_Resultado_Contato__c = 'Atendeu'
      ),
      new Task(Id = email.Id, SOL_Contato_Efetivado__c = true)
    };
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(true, d.SOL_Contato_Efetivado__c, 'Lead sinalizado.');
    System.assertNotEquals(null, d.SOL_Data_Contato_Efetivado__c, 'Com data.');
    System.assertEquals(
      'Cancelada',
      lerTarefa(whats.Id).Status,
      'A pendente foi cancelada uma única vez.'
    );
    System.assertEquals(0, abertasDeContato(l.Id), 'Nada pendente.');
  }

  /** (9) Bulk: o custo não escala com o número de Leads. */
  @IsTest
  static void bulkDeLeadsNaoEscalaConsultasNemDml() {
    montarCenario(2);
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 6; i++) {
      leads.add(novoLeadSOL('S9449f' + i, 'Recuperação Tributária'));
    }
    for (Lead l : leads) {
      contatoAberto(l, 'Ligação');
      contatoAberto(l, 'WhatsApp');
    }

    List<Lead> um = new List<Lead>{
      new Lead(Id = leads[0].Id, SOL_Contato_Efetivado__c = true)
    };
    List<Lead> lote = new List<Lead>();
    for (Integer i = 1; i < leads.size(); i++) {
      lote.add(new Lead(Id = leads[i].Id, SOL_Contato_Efetivado__c = true));
    }

    Test.startTest();
    Integer q1 = Limits.getQueries();
    Integer d1 = Limits.getDmlStatements();
    update um;
    Integer qUm = Limits.getQueries() - q1;
    Integer dUm = Limits.getDmlStatements() - d1;

    Integer q2 = Limits.getQueries();
    Integer d2 = Limits.getDmlStatements();
    update lote;
    Integer qLote = Limits.getQueries() - q2;
    Integer dLote = Limits.getDmlStatements() - d2;
    Test.stopTest();

    System.assertEquals(
      qUm,
      qLote,
      'As consultas não escalam com o tamanho do lote.'
    );
    System.assertEquals(dUm, dLote, 'E o DML também não.');
    for (Lead l : leads) {
      System.assertEquals(
        true,
        recarregar(l.Id).SOL_Contato_Efetivado__c,
        'Todos os Leads do lote foram sinalizados.'
      );
      System.assertEquals(
        0,
        abertasDeContato(l.Id),
        'E nenhum ficou com tarefa de contato pendente.'
      );
    }
  }

  // ==================================================== fora do escopo

  /** (10) Outra BU, convertido e negócio perdido não são alcançados. */
  @IsTest
  static void leadsForaDoEscopoNaoSaoAlcancados() {
    montarCenario(2);

    Lead outraBU = new Lead(
      LastName = 'Fora da BU',
      Company = 'Outra Empresa',
      Status = statusLead()
    );
    insert outraBU;
    Task tarefaOutraBU = new Task(
      Subject = 'Contato de outra BU',
      WhoId = outraBU.Id,
      OwnerId = UserInfo.getUserId(),
      Status = 'Open',
      ActivityDate = Date.today(),
      SOL_Tipo_Tarefa__c = 'Contato',
      SOL_Canal_Contato__c = 'Ligação'
    );
    insert tarefaOutraBU;

    Lead perdido = novoLeadSOL('S9449g', 'Recuperação Tributária');
    Task tarefaPerdido = contatoAberto(perdido, 'E-mail');
    update new Lead(
      Id = perdido.Id,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = 'Negócio perdido'
    );

    Test.startTest();
    // Outra BU: o Flow nem dispara (filtra Record Type SOL).
    update new Lead(Id = outraBU.Id, SOL_Contato_Efetivado__c = true);
    // Lead perdido: o Flow dispara, mas o serviço se recusa a sinalizar.
    update new Lead(Id = perdido.Id, SOL_Contato_Efetivado__c = true);
    Test.stopTest();

    System.assertEquals(
      'Open',
      lerTarefa(tarefaOutraBU.Id).Status,
      'A tarefa do Lead de outra BU continua aberta.'
    );
    System.assertEquals(
      'Cancelada',
      lerTarefa(tarefaPerdido.Id).Status,
      'No Lead perdido, o encerramento por perda (CLICKUP-9425) já havia cancelado a tarefa.'
    );
    System.assert(
      recarregar(perdido.Id).SOL_Data_Contato_Efetivado__c == null,
      'E o serviço não estampa data de contato efetivado num negócio perdido.'
    );
  }

  /**
   * (11) Falha no cancelamento desfaz TAMBÉM a alteração direta do flag.
   *
   * LIMITE DECLARADO: `Test.setReadOnlyApplicationMode(true)` derruba todo DML,
   * inclusive o update do próprio Lead, então este teste não distingue "falhou
   * ao gravar o Lead" de "falhou no cancelamento e a plataforma reverteu". O
   * que ele fixa é o resultado observável — o flag não persiste. O
   * encadeamento é garantido por `CurrentTransaction` e pela ausência de fault
   * path no Flow, e está evidenciado no E2E.
   */
  @IsTest
  static void falhaNoCancelamentoDesfazAAlteracaoDoFlag() {
    montarCenario(2);
    Lead l = novoLeadSOL('S9449h', 'Recuperação Tributária');
    Task pendente = contatoAberto(l, 'Ligação');

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean falhou = false;
    try {
      marcarDireto(l.Id);
    } catch (Exception e) {
      falhou = true;
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(falhou, 'A gravação não passou.');
    System.assertEquals(
      false,
      recarregar(l.Id).SOL_Contato_Efetivado__c,
      'O flag NÃO ficou marcado.'
    );
    System.assertEquals(
      'Open',
      lerTarefa(pendente.Id).Status,
      'E a tarefa continua aberta.'
    );
  }

  /** (13) Recuperação Tributária e ART 360 se comportam igual. */
  @IsTest
  static void osDoisProdutosSeComportamIgual() {
    montarCenario(2);
    Lead rt = novoLeadSOL('S9449i', 'Recuperação Tributária');
    Lead art = novoLeadSOL('S9449j', 'ART 360');
    Map<Id, Id> pendentePorLead = new Map<Id, Id>();
    for (Lead l : new List<Lead>{ rt, art }) {
      pendentePorLead.put(l.Id, contatoAberto(l, 'WhatsApp').Id);
    }

    Test.startTest();
    update new List<Lead>{
      new Lead(Id = rt.Id, SOL_Contato_Efetivado__c = true),
      new Lead(Id = art.Id, SOL_Contato_Efetivado__c = true)
    };
    Test.stopTest();

    for (Id leadId : pendentePorLead.keySet()) {
      System.assertEquals(
        true,
        recarregar(leadId).SOL_Contato_Efetivado__c,
        'Lead sinalizado nos dois produtos.'
      );
      Task t = lerTarefa(pendentePorLead.get(leadId));
      System.assertEquals('Cancelada', t.Status, 'Tarefa cancelada.');
      System.assertEquals(MOTIVO, t.SOL_Motivo_Cancelamento__c, 'Com o motivo.');
    }
  }

  /**
   * (14) Vendedor e gestor continuam enxergando o status e o motivo das tarefas
   * canceladas. Medido por `getDescribe()` sob `System.runAs`, porque DML de
   * Apex roda em modo de sistema e não aplica FLS.
   */
  @IsTest
  static void vendedorEGestorLeemStatusEMotivoDasCanceladas() {
    Id perfilStd = UserInfo.getProfileId();
    for (Profile p : [
      SELECT Id, Name
      FROM Profile
      WHERE UserType = 'Standard' AND Name = 'Standard User'
      LIMIT 1
    ]) {
      perfilStd = p.Id;
    }
    User vend = vendedor('fls1');
    vend.ProfileId = perfilStd;
    User gest = vendedor('fls2');
    gest.ProfileId = perfilStd;
    System.runAs(contextoAtual()) {
      insert new List<User>{ vend, gest };
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = vend.Id,
          PermissionSetId = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'PS_SOL_Comercial'
            LIMIT 1
          ]
          .Id
        ),
        new PermissionSetAssignment(
          AssigneeId = gest.Id,
          PermissionSetId = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'PS_SOL_Distribuicao_Admin'
            LIMIT 1
          ]
          .Id
        )
      };
    }

    Test.startTest();
    for (User u : new List<User>{ vend, gest }) {
      System.runAs(new User(Id = u.Id)) {
        System.assert(
          Task.Status.getDescribe().isAccessible(),
          'Lê o status da tarefa cancelada.'
        );
        System.assert(
          Task.SOL_Motivo_Cancelamento__c.getDescribe().isAccessible(),
          'E o motivo do cancelamento.'
        );
      }
    }
    Test.stopTest();
  }
}
