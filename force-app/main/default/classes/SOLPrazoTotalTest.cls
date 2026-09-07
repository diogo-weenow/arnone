/**
 * CLICKUP-9424 — Card 13 — Testes da reatribuição automática por estouro do
 * prazo total de 30 dias úteis.
 *
 * O prazo nasce em Lead.SOL_Data_Contato_Efetivado__c, é transportado por
 * SOL_ConverterLead para Opportunity.SOL_Data_Inicio_Ciclo_Comercial__c e o
 * limite (30 dias ÚTEIS por SOLBusinessHoursHelper) fica em
 * SOL_Prazo_Total_Comercial__c. Quando vence e a Opp continua aberta,
 * SOLPrazoTotalService a transfere ao próximo vendedor elegível da fila,
 * levando as Tasks ABERTAS e registrando data/motivo/quantidade — uma única vez
 * por Oportunidade.
 *
 * A fila usada nos testes é SINTÉTICA (queueDeveloperNameOverride), como nos
 * cards anteriores. Concorrência real não é simulável em Apex: a proteção é o
 * FOR UPDATE no singleton, nas Oportunidades e nas Tasks — cobre-se a
 * idempotência SEQUENCIAL e a atomicidade.
 */
@IsTest
private class SOLPrazoTotalTest {
  private static final String FILA_SINTETICA = 'RR_Prazo_Total_SOL_9424';
  private static final String PRODUTO_RT = 'Recuperação Tributária';
  private static final String PRODUTO_ART = 'ART 360';
  private static final String CNPJ = '11222333000181';
  private static final String CNPJ_MASCARADO = '11.222.333/0001-81';
  private static final String TZ_SP = 'America/Sao_Paulo';
  private static Integer seq = 0;

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static String rnd() {
    seq++;
    return seq + 'x' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
  }

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

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

  private static User vendedor(String tag) {
    return new User(
      FirstName = 'PT',
      LastName = 'Vend ' + tag,
      Alias = ('pt' + tag).left(8),
      Email = 'pt.' + tag + '@arnone.invalid',
      Username = 'pt.' +
        tag +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9424.test.invalid',
      ProfileId = perfilStandard(),
      TimeZoneSidKey = TZ_SP,
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  /**
   * Cria `qtd` vendedores ativos (+ `inativos` desativados) numa fila sintética
   * habilitada para Lead e aponta o serviço para ela. Devolve os ativos
   * ordenados por Id ASC — a mesma ordem do roster do round-robin.
   */
  private static List<Id> montarFila(Integer qtd, Integer inativos) {
    List<User> ativos = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      ativos.add(vendedor('a' + i + rnd().left(4)));
    }
    List<User> desativados = new List<User>();
    for (Integer i = 0; i < inativos; i++) {
      desativados.add(vendedor('i' + i + rnd().left(4)));
    }

    System.runAs(contextoAtual()) {
      List<User> todos = new List<User>(ativos);
      todos.addAll(desativados);
      if (!todos.isEmpty()) {
        insert todos;
      }
      Group fila = new Group(
        Name = 'RR Prazo Total SOL 9424',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : todos) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = u.Id));
      }
      if (!gms.isEmpty()) {
        insert gms;
      }
      // Desativa depois de entrar na fila: membro da fila, mas fora do roster.
      List<User> paraDesativar = new List<User>();
      for (User u : desativados) {
        paraDesativar.add(new User(Id = u.Id, IsActive = false));
      }
      if (!paraDesativar.isEmpty()) {
        update paraDesativar;
      }
    }

    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    List<Id> ids = new List<Id>();
    for (User u : ativos) {
      ids.add(u.Id);
    }
    ids.sort();
    return ids;
  }

  private static List<Id> montarFila(Integer qtd) {
    return montarFila(qtd, 0);
  }

  private static Id rtOppSOL() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id rtLeadSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id bhId() {
    Id v = SOLBusinessHoursHelper.businessHoursId();
    System.assertNotEquals(null, v, 'Business Hours comercial é pré-requisito.');
    return v;
  }

  private static Datetime prazoEsperado(Datetime inicio) {
    return SOLBusinessHoursHelper.prazoEmDiasUteis(bhId(), inicio, 30);
  }

  /**
   * Opportunity SOL pronta para o teste. `inicio` = início do ciclo comercial
   * (null => sem data, sem prazo). `prazo` = limite gravado (null => calculado
   * a partir de `inicio`, quando houver). `etapaFinal` permite fechar a Opp.
   */
  private static Id novaOpp(
    String produto,
    Boolean oppSOL,
    Id owner,
    Datetime inicio,
    Datetime prazo,
    String etapaFinal
  ) {
    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd(),
      AccountId = a.Id,
      CloseDate = Date.today().addDays(60),
      StageName = 'Diagnóstico',
      SOL_Produto_Negocio__c = produto,
      SOL_ECAC_Consulta_Realizada__c = true,
      SOL_ECAC_Data_Consulta__c = Date.today(),
      SOL_ECAC_Resultado__c = 'Valor a recuperar',
      SOL_Valor_Recuperavel__c = 1000,
      SOL_Apresentacao_Realizada__c = true,
      SOL_Data_Apresentacao__c = Date.today(),
      SOL_Resultado_Apresentacao__c = 'Sucesso',
      SOL_Percentual_Comissao__c = 20,
      SOL_Valor_Servico__c = 5000
    );
    if (oppSOL) {
      o.RecordTypeId = rtOppSOL();
    }
    if (owner != null) {
      o.OwnerId = owner;
    }
    if (inicio != null) {
      o.SOL_Data_Inicio_Ciclo_Comercial__c = inicio;
      o.SOL_Prazo_Total_Comercial__c = prazo == null ? prazoEsperado(inicio) : prazo;
    } else if (prazo != null) {
      o.SOL_Prazo_Total_Comercial__c = prazo;
    }
    insert o;
    if (etapaFinal != null && etapaFinal != 'Diagnóstico') {
      update new Opportunity(Id = o.Id, StageName = 'Negociação');
      if (etapaFinal != 'Negociação') {
        Opportunity fecha = new Opportunity(Id = o.Id, StageName = etapaFinal);
        if (etapaFinal == 'Perdido') {
          fecha.SOL_Motivo_Perda__c = 'Sem retorno';
        }
        update fecha;
      }
    }
    return o.Id;
  }

  /** Opp vencida e aberta, do dono informado. */
  private static Id oppVencida(String produto, Id owner) {
    return novaOpp(produto, true, owner, Datetime.now().addDays(-60), Datetime.now().addDays(-1), null);
  }

  private static Opportunity opp(Id oppId) {
    return [
      SELECT
        Id,
        OwnerId,
        StageName,
        SOL_Data_Inicio_Ciclo_Comercial__c,
        SOL_Prazo_Total_Comercial__c,
        SOL_Data_Reatribuicao_Prazo__c,
        SOL_Motivo_Reatribuicao_Prazo__c,
        SOL_Qtd_Reatribuicoes_Prazo__c,
        SOL_Status_Reatribuicao_Prazo__c,
        SOL_ECAC_Resultado__c,
        SOL_Valor_Recuperavel__c
      FROM Opportunity
      WHERE Id = :oppId
    ];
  }

  private static Task tarefa(Id oppId, Id owner, String status, String tipo) {
    Task t = new Task(
      Subject = 'T ' + rnd(),
      WhatId = oppId,
      OwnerId = owner,
      Status = 'Open',
      ActivityDate = Date.today().addDays(5),
      SOL_Tipo_Tarefa__c = tipo
    );
    insert t;
    if (status == 'Cancelada') {
      // VR SOL_Cancelada_Exige_Classificacao (CLICKUP-9417): "Cancelada" exige
      // tipo e motivo do cancelamento.
      update new Task(
        Id = t.Id,
        Status = status,
        SOL_Tipo_Tarefa__c = tipo == null ? 'Contato' : tipo,
        SOL_Motivo_Cancelamento__c = 'Opt-out'
      );
    } else if (status != 'Open') {
      update new Task(Id = t.Id, Status = status);
    }
    return t;
  }

  private static Id ownerDaTask(Id taskId) {
    return [SELECT OwnerId FROM Task WHERE Id = :taskId].OwnerId;
  }

  // ================================================== CONVERSÃO (origem do prazo)
  //
  // Blocker 3 — cobertura funcional REAL de SOL_ConverterLead: o transporte da
  // data do contato efetivado e o cálculo do prazo de 30 dias úteis são
  // exercitados pela conversão de ponta a ponta, executada por um usuário com o
  // perfil de quem usa a ação em produção (Standard + PS_Comercial +
  // PS_SOL_Comercial). PS_Comercial concede FLS de Account.CNPJ__c /
  // Account.Unidades_Atendidas__c e "Converter Leads"; PS_SOL_Comercial concede
  // os campos da jornada e o acesso à classe. Nada é concedido de forma ampla
  // ou permanente — são os mesmos conjuntos que a BU já usa.

  /** Standard User + PS_Comercial + PS_SOL_Comercial: a persona real da ação. */
  private static User usuarioComercialSOL() {
    User u = vendedor('cs' + rnd().left(4));
    System.runAs(contextoAtual()) {
      insert u;
      List<PermissionSetAssignment> asg = new List<PermissionSetAssignment>();
      for (PermissionSet ps : [
        SELECT Id
        FROM PermissionSet
        WHERE Name IN ('PS_Comercial', 'PS_SOL_Comercial')
      ]) {
        asg.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
      }
      insert asg;
    }
    return u;
  }

  /**
   * Lead SOL apto para conversão (procuração recebida + documento anexado),
   * montado no contexto ADMIN e transferido ao vendedor Comercial que fará a
   * conversão. Se `comContatoEfetivado`, registra o contato efetivado pela via
   * oficial (SOLDistribuicaoService.registrarContatoEfetivado). Devolve o Lead
   * relido, já com SOL_Data_Contato_Efetivado__c quando aplicável.
   *
   * A montagem fica no admin porque a inserção de um Lead SOL dispara a
   * distribuição (CLICKUP-9394): o Lead ganha um proprietário de fila e o
   * vendedor teste não teria acesso de cross-reference para editá-lo. A
   * CONVERSÃO em si — o que este bloco de testes valida — roda como o vendedor.
   */
  private static Lead leadAptoParaConverter(String produto, Boolean comContatoEfetivado, Id donoFinal) {
    Lead l = new Lead(
      OwnerId = donoFinal,
      RecordTypeId = rtLeadSOL(),
      FirstName = 'C',
      LastName = 'Lead ' + rnd(),
      Company = 'Empresa ' + rnd(),
      Email = 'lead.' + rnd().left(8) + '@exemplo.invalid',
      Status = 'Apto para Conversão',
      CNPJ__c = '11.222.333/0001-81',
      SOL_Produto_Interesse__c = produto
    );
    Database.DMLOptions opc = new Database.DMLOptions();
    opc.duplicateRuleHeader.allowSave = true;
    Database.insert(l, opc);

    if (comContatoEfetivado) {
      SOLDistribuicaoService.registrarContatoEfetivado(new List<Id>{ l.Id });
    }

    update new Lead(
      Id = l.Id,
      OwnerId = donoFinal,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today(),
      // Portão do Flow SOL_Validar_Avanco_Reuniao_Procuracao (CLICKUP-9419): a
      // conversão exige a reunião comercial consolidada.
      SOL_Data_Reuniao_Realizada__c = Datetime.now().addDays(-2)
    );

    ContentVersion cv = new ContentVersion(
      Title = 'Procuracao ' + rnd().left(6),
      PathOnClient = 'procuracao.txt',
      VersionData = Blob.valueOf('documento')
    );
    insert cv;
    insert new ContentDocumentLink(
      ContentDocumentId = [
        SELECT ContentDocumentId
        FROM ContentVersion
        WHERE Id = :cv.Id
      ]
      .ContentDocumentId,
      LinkedEntityId = l.Id,
      ShareType = 'V'
    );

    return [
      SELECT Id, SOL_Data_Contato_Efetivado__c, SOL_Produto_Interesse__c
      FROM Lead
      WHERE Id = :l.Id
    ];
  }

  private static SOL_ConverterLead.Resultado converter(Id leadId) {
    SOL_ConverterLead.Pedido p = new SOL_ConverterLead.Pedido();
    p.leadId = leadId;
    return SOL_ConverterLead.converter(new List<SOL_ConverterLead.Pedido>{ p })[0];
  }

  private static Opportunity oppConvertida(Id leadId) {
    return [
      SELECT
        Id,
        SOL_Produto_Negocio__c,
        SOL_Data_Inicio_Ciclo_Comercial__c,
        SOL_Prazo_Total_Comercial__c
      FROM Opportunity
      WHERE Id = :[SELECT ConvertedOpportunityId FROM Lead WHERE Id = :leadId].ConvertedOpportunityId
    ];
  }

  @IsTest
  static void conversaoRT_transportaDataEGravaPrazo30DiasUteis() {
    montarFila(1); // a inserção do Lead SOL dispara a distribuição
    User comercial = usuarioComercialSOL();
    Lead l = leadAptoParaConverter(PRODUTO_RT, true, comercial.Id);
    System.assertNotEquals(
      null,
      l.SOL_Data_Contato_Efetivado__c,
      'Pré-condição: contato efetivado registrado no Lead.'
    );
    Datetime prazoEsper = SOLPrazoTotalService.calcularPrazoTotal(l.SOL_Data_Contato_Efetivado__c);

    Test.startTest();
    System.runAs(comercial) {
      SOL_ConverterLead.Resultado r = converter(l.Id);
      System.assert(r.convertido, 'Conversão RT concluída: ' + r.mensagem);
    }
    Test.stopTest();

    Opportunity o = oppConvertida(l.Id);
    System.assertEquals(PRODUTO_RT, o.SOL_Produto_Negocio__c);
    System.assertEquals(
      l.SOL_Data_Contato_Efetivado__c,
      o.SOL_Data_Inicio_Ciclo_Comercial__c,
      'A Oportunidade recebe EXATAMENTE a data original do contato efetivado.'
    );
    System.assertEquals(
      prazoEsper,
      o.SOL_Prazo_Total_Comercial__c,
      'O limite gravado é o de 30 dias úteis a partir dessa data.'
    );
  }

  @IsTest
  static void conversaoART360_transportaDataEGravaPrazo30DiasUteis() {
    montarFila(1);
    User comercial = usuarioComercialSOL();
    Lead l = leadAptoParaConverter(PRODUTO_ART, true, comercial.Id);
    Datetime prazoEsper = SOLPrazoTotalService.calcularPrazoTotal(l.SOL_Data_Contato_Efetivado__c);

    Test.startTest();
    System.runAs(comercial) {
      SOL_ConverterLead.Resultado r = converter(l.Id);
      System.assert(r.convertido, 'Conversão ART 360 concluída: ' + r.mensagem);
    }
    Test.stopTest();

    Opportunity o = oppConvertida(l.Id);
    System.assertEquals(PRODUTO_ART, o.SOL_Produto_Negocio__c);
    System.assertEquals(
      l.SOL_Data_Contato_Efetivado__c,
      o.SOL_Data_Inicio_Ciclo_Comercial__c,
      'ART 360 também transporta a data original do contato efetivado.'
    );
    System.assertEquals(
      prazoEsper,
      o.SOL_Prazo_Total_Comercial__c,
      'ART 360 usa a MESMA régua de 30 dias úteis.'
    );
  }

  @IsTest
  static void conversaoSemContatoEfetivado_naoGravaPrazo() {
    montarFila(1);
    User comercial = usuarioComercialSOL();

    // O mesmo guarda que a conversão aplica: sem a data, nada é calculado.
    System.assertEquals(null, SOLPrazoTotalService.calcularPrazoTotal(null));

    Lead l = leadAptoParaConverter(PRODUTO_RT, false, comercial.Id);
    System.assertEquals(
      null,
      l.SOL_Data_Contato_Efetivado__c,
      'Pré-condição: Lead SEM contato efetivado.'
    );

    Test.startTest();
    System.runAs(comercial) {
      SOL_ConverterLead.Resultado r = converter(l.Id);
      System.assert(
        r.convertido,
        'A conversão prossegue mesmo sem contato efetivado: ' + r.mensagem
      );
    }
    Test.stopTest();

    Opportunity o = oppConvertida(l.Id);
    System.assertEquals(
      null,
      o.SOL_Data_Inicio_Ciclo_Comercial__c,
      'Sem contato efetivado, o início do ciclo não é gravado (regra existente).'
    );
    System.assertEquals(
      null,
      o.SOL_Prazo_Total_Comercial__c,
      'Sem data de início, não há prazo total.'
    );
  }

  @IsTest
  static void conversaoComCalendarioIndisponivel_desfazTudo() {
    montarFila(1);
    User comercial = usuarioComercialSOL();
    Lead l = leadAptoParaConverter(PRODUTO_RT, true, comercial.Id);
    Integer oppsAntes = [SELECT COUNT() FROM Opportunity];

    Test.startTest();
    System.runAs(comercial) {
      // Calendário comercial ausente: o prazo não pode ser calculado.
      SOLBusinessHoursHelper.overrideBusinessHours(null);
      SOL_ConverterLead.Resultado r = converter(l.Id);

      System.assertEquals(false, r.convertido, 'Sem calendário, a conversão NÃO se completa.');
      System.assertEquals(
        SOL_ConverterLead.CALENDARIO_INDISPONIVEL,
        r.mensagem,
        'Mensagem controlada e acionável sobre o calendário.'
      );
    }
    Test.stopTest();

    System.assertEquals(
      false,
      [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
      'O Lead continua NÃO convertido — nada parcial.'
    );
    System.assertEquals(
      oppsAntes,
      [SELECT COUNT() FROM Opportunity],
      'Nenhuma Oportunidade permaneceu da conversão abortada.'
    );
  }

  /**
   * Cobertura funcional (Blocker 3) — os portões de impedimentoPara, exercidos
   * um a um. São checagens puras (sem SOQL/DML): não precisam do usuário
   * Comercial nem de fixtures em banco.
   */
  @IsTest
  static void impedimentoParaCobreTodosOsPortoes() {
    Lead convertido = new Lead(IsConverted = true, RecordType = new RecordType(DeveloperName = 'SOL'));
    System.assertEquals('Este lead já foi convertido.', SOL_ConverterLead.impedimentoPara(convertido, 1));

    Lead outraBU = new Lead(IsConverted = false, RecordType = new RecordType(DeveloperName = 'STE'));
    System.assert(
      SOL_ConverterLead.impedimentoPara(outraBU, 1).startsWith('Este lead não é da Arnone Soluções')
    );

    Lead semProduto = new Lead(
      IsConverted = false,
      RecordType = new RecordType(DeveloperName = 'SOL'),
      SOL_Produto_Interesse__c = null
    );
    System.assert(SOL_ConverterLead.impedimentoPara(semProduto, 1).startsWith('Informe o produto'));

    Lead semCnpj = new Lead(
      IsConverted = false,
      RecordType = new RecordType(DeveloperName = 'SOL'),
      SOL_Produto_Interesse__c = PRODUTO_RT,
      CNPJ__c = null
    );
    System.assert(SOL_ConverterLead.impedimentoPara(semCnpj, 1).startsWith('Informe o CNPJ'));

    Lead semProcuracao = new Lead(
      IsConverted = false,
      RecordType = new RecordType(DeveloperName = 'SOL'),
      SOL_Produto_Interesse__c = PRODUTO_RT,
      CNPJ__c = CNPJ,
      SOL_Status_Procuracao__c = 'Solicitada'
    );
    System.assert(
      SOL_ConverterLead.impedimentoPara(semProcuracao, 1).startsWith('A procuração ainda não foi recebida')
    );

    Lead semArquivo = new Lead(
      IsConverted = false,
      RecordType = new RecordType(DeveloperName = 'SOL'),
      SOL_Produto_Interesse__c = PRODUTO_RT,
      CNPJ__c = CNPJ,
      SOL_Status_Procuracao__c = 'Recebida'
    );
    System.assert(
      SOL_ConverterLead.impedimentoPara(semArquivo, 0).startsWith('A procuração está marcada')
    );

    Lead apto = new Lead(
      IsConverted = false,
      RecordType = new RecordType(DeveloperName = 'SOL'),
      SOL_Produto_Interesse__c = PRODUTO_RT,
      CNPJ__c = CNPJ,
      SOL_Status_Procuracao__c = 'Recebida',
      SOL_Data_Recebimento_Procuracao__c = Date.today()
    );
    System.assertEquals(null, SOL_ConverterLead.impedimentoPara(apto, 1));
    System.assert(SOL_ConverterLead.resumoDe(apto, 1).contains(CNPJ), 'resumoDe usa os dados do Lead.');
  }

  /** Cobertura funcional — as duas grafias do CNPJ e a busca de Conta por elas. */
  @IsTest
  static void variantesDeCnpjEBuscaDeContaExistente() {
    Set<String> vazio = SOL_ConverterLead.variantesDe(null);
    System.assert(vazio.isEmpty(), 'CNPJ vazio não gera variantes.');

    Set<String> variantes = SOL_ConverterLead.variantesDe('11.222.333/0001-81');
    System.assert(variantes.contains('11222333000181'), 'Inclui os só-dígitos.');
    System.assert(variantes.contains('11.222.333/0001-81'), 'Inclui o mascarado.');

    User comercial = usuarioComercialSOL();
    System.runAs(comercial) {
      System.assertEquals(
        null,
        SOL_ConverterLead.contaPorCnpj('99.999.999/0001-99'),
        'Sem Conta com esse CNPJ: null.'
      );

      Account a = new Account(Name = 'Conta CNPJ ' + rnd(), CNPJ__c = CNPJ, Unidades_Atendidas__c = 'SOL');
      Database.DMLOptions opc = new Database.DMLOptions();
      opc.duplicateRuleHeader.allowSave = true;
      Database.insert(a, opc);

      Account achada = SOL_ConverterLead.contaPorCnpj(CNPJ_MASCARADO);
      System.assertEquals(a.Id, achada.Id, 'Encontra a Conta pela variante mascarada, mesmo com o CNPJ cru gravado.');
    }
  }

  /**
   * Cobertura funcional (Blocker 3) — conversão REAPROVEITANDO uma Conta
   * existente (contaId informado): completa o CNPJ/unidade só quando faltam,
   * sem sobrescrever o que já está preenchido.
   */
  @IsTest
  static void conversaoReaproveitaContaExistente() {
    montarFila(1);
    User comercial = usuarioComercialSOL();
    Id contaId;
    System.runAs(comercial) {
      Account a = new Account(Name = 'Conta Existente ' + rnd(), CNPJ__c = CNPJ, Unidades_Atendidas__c = 'SOL');
      Database.DMLOptions opc = new Database.DMLOptions();
      opc.duplicateRuleHeader.allowSave = true;
      Database.insert(a, opc);
      contaId = a.Id;
    }
    Lead l = leadAptoParaConverter(PRODUTO_RT, true, comercial.Id);

    Test.startTest();
    System.runAs(comercial) {
      SOL_ConverterLead.Pedido p = new SOL_ConverterLead.Pedido();
      p.leadId = l.Id;
      p.contaId = contaId;
      SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
        new List<SOL_ConverterLead.Pedido>{ p }
      )[0];
      System.assert(r.convertido, 'Conversão reaproveitando conta: ' + r.mensagem);
      System.assertEquals(contaId, (Id) r.contaId, 'A Conta reaproveitada é a informada, não uma nova.');
    }
    Test.stopTest();

    Opportunity o = oppConvertida(l.Id);
    System.assertEquals(
      l.SOL_Data_Contato_Efetivado__c,
      o.SOL_Data_Inicio_Ciclo_Comercial__c,
      'O reaproveitamento de Conta não muda o transporte da data do contato.'
    );
  }

  // ================================================== RÉGUA DOS 30 DIAS ÚTEIS

  @IsTest
  static void prazoTrintaDiasUteisExato() {
    Id bh = bhId();
    // Quarta 2026-09-02, meio-dia GMT. Conta 30 dias úteis: pula 2 fins de
    // semana completos + o restante, terminando em 2026-10-14 (quarta).
    Datetime origem = Datetime.newInstanceGmt(2026, 9, 2, 12, 0, 0);
    Datetime prazo = SOLBusinessHoursHelper.prazoEmDiasUteis(bh, origem, 30);
    Date dataPrazo = SOLBusinessHoursHelper.dataEm(prazo, TZ_SP);

    // Confere contando os dias úteis do intervalo (origem, prazo].
    Integer uteis = 0;
    Integer naoUteis = 0;
    Date d = SOLBusinessHoursHelper.dataEm(origem, TZ_SP);
    while (d < dataPrazo) {
      d = d.addDays(1);
      Datetime prox = BusinessHours.nextStartDate(
        bh,
        Datetime.newInstanceGmt(d, Time.newInstance(0, 0, 0, 0))
      );
      if (prox != null && SOLBusinessHoursHelper.dataEm(prox, TZ_SP) == d) {
        uteis++;
      } else {
        naoUteis++;
      }
    }
    System.assertEquals(30, uteis, 'Exatamente 30 dias úteis em (origem, prazo].');
    System.assert(naoUteis >= 8, 'Pelo menos 4 fins de semana pulados: ' + naoUteis);
    System.assert(
      SOLBusinessHoursHelper.dataEm(origem, TZ_SP).daysBetween(dataPrazo) >= 40,
      '30 dias úteis = pelo menos 40 dias corridos.'
    );
  }

  @IsTest
  static void prazoIgnoraHorarioForaDoExpedienteEFimDeSemana() {
    Id bh = bhId();
    // Sábado 2026-09-12 às 23:00 GMT (20:00 SP, fora do expediente) e a
    // segunda seguinte ao meio-dia caem no MESMO prazo: a régua conta DATAS
    // úteis a partir do dia seguinte, não o horário da origem.
    Datetime sabadoNoite = Datetime.newInstanceGmt(2026, 9, 12, 23, 0, 0);
    Datetime domingo = Datetime.newInstanceGmt(2026, 9, 13, 12, 0, 0);
    System.assertEquals(
      SOLBusinessHoursHelper.dataEm(SOLBusinessHoursHelper.prazoEmDiasUteis(bh, sabadoNoite, 30), TZ_SP),
      SOLBusinessHoursHelper.dataEm(SOLBusinessHoursHelper.prazoEmDiasUteis(bh, domingo, 30), TZ_SP),
      'Sábado à noite e domingo produzem o mesmo prazo (nenhum é dia útil).'
    );
    // O prazo é sempre a ABERTURA de um dia útil no fuso de São Paulo.
    Datetime prazo = SOLBusinessHoursHelper.prazoEmDiasUteis(bh, sabadoNoite, 30);
    Date dataSP = SOLBusinessHoursHelper.dataEm(prazo, TZ_SP);
    Datetime abertura = BusinessHours.nextStartDate(
      bh,
      Datetime.newInstanceGmt(dataSP, Time.newInstance(0, 0, 0, 0))
    );
    System.assertEquals(abertura, prazo, 'O prazo é a abertura efetiva do dia útil (timezone SP).');
  }

  // ================================================== LIMITE / FECHAMENTO

  @IsTest
  static void naoReatribuiAntesDoLimite() {
    List<Id> vs = montarFila(3);
    Id oppId = novaOpp(
      PRODUTO_RT,
      true,
      vs[0],
      Datetime.now().addDays(-1),
      Datetime.now().addDays(5), // prazo no futuro
      null
    );

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas);
    System.assertEquals(1, r.ignoradas);
    System.assertEquals(vs[0], opp(oppId).OwnerId, 'Proprietário intacto antes do limite.');
  }

  @IsTest
  static void reatribuiExatamenteNoLimite() {
    List<Id> vs = montarFila(3);
    // Prazo exatamente "agora" (o serviço usa <=): 1 segundo atrás garante
    // que System.now() dentro do serviço já passou do limite.
    Id oppId = novaOpp(
      PRODUTO_RT,
      true,
      vs[0],
      Datetime.now().addDays(-45),
      Datetime.now().addSeconds(-1),
      null
    );

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(1, r.reatribuidas, 'No limite já reatribui.');
    System.assertNotEquals(vs[0], opp(oppId).OwnerId);
  }

  @IsTest
  static void ganhoEPerdidoSaoIgnorados() {
    List<Id> vs = montarFila(3);
    Id ganha = novaOpp(PRODUTO_RT, true, vs[0], Datetime.now().addDays(-60), Datetime.now().addDays(-1), 'Ganho');
    Id perdida = novaOpp(PRODUTO_RT, true, vs[0], Datetime.now().addDays(-60), Datetime.now().addDays(-1), 'Perdido');

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ ganha, perdida }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas, 'Ganho/Perdido nunca são reatribuídas.');
    System.assertEquals(2, r.ignoradas);
    System.assertEquals(vs[0], opp(ganha).OwnerId);
    System.assertEquals(vs[0], opp(perdida).OwnerId);
    System.assertEquals('Ganho', opp(ganha).StageName);
    System.assertEquals('Perdido', opp(perdida).StageName);
  }

  // ================================================== ROTAÇÃO

  @IsTest
  static void escolheProximoAtivoExcluindoOAtual() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[1]);

    Test.startTest();
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    Test.stopTest();

    Id novo = opp(oppId).OwnerId;
    System.assertNotEquals(vs[1], novo, 'O proprietário atual é excluído da escolha.');
    System.assert(new Set<Id>(vs).contains(novo), 'O novo dono é um vendedor direto ativo da fila.');
  }

  @IsTest
  static void proprietarioForaDoRosterRecebeQualquerAtivo() {
    List<Id> vs = montarFila(2);
    // Dono atual = usuário do contexto (não é membro da fila).
    Id oppId = oppVencida(PRODUTO_RT, UserInfo.getUserId());

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(1, r.reatribuidas);
    System.assert(new Set<Id>(vs).contains(opp(oppId).OwnerId));
  }

  @IsTest
  static void usuarioInativoNaoEntraNoRoster() {
    List<Id> vs = montarFila(1, 2); // 1 ativo + 2 inativos na fila
    Id oppId = oppVencida(PRODUTO_RT, UserInfo.getUserId());

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(1, r.reatribuidas);
    System.assertEquals(vs[0], opp(oppId).OwnerId, 'Só o único ativo pode receber.');
  }

  @IsTest
  static void unicoVendedorEhODono_situacaoControlada() {
    List<Id> vs = montarFila(1);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas);
    System.assertEquals(1, r.semOutroVendedor);
    Opportunity o = opp(oppId);
    System.assertEquals(vs[0], o.OwnerId, 'Proprietário não é alterado.');
    System.assertEquals('Sem outro vendedor', o.SOL_Status_Reatribuicao_Prazo__c);
    System.assertEquals(SOLPrazoTotalService.MOTIVO_SEM_OUTRO_VENDEDOR, o.SOL_Motivo_Reatribuicao_Prazo__c);
    System.assert(
      o.SOL_Qtd_Reatribuicoes_Prazo__c == null || o.SOL_Qtd_Reatribuicoes_Prazo__c == 0,
      'NÃO é marcada como processada: permite nova tentativa.'
    );
  }

  @IsTest
  static void filaVaziaNaoAlteraProprietario() {
    List<Id> vs = montarFila(0); // fila existe, habilitada para Lead, sem membros ativos
    Id oppId = oppVencida(PRODUTO_RT, UserInfo.getUserId());

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas);
    System.assertEquals(1, r.semOutroVendedor);
    System.assertEquals(UserInfo.getUserId(), opp(oppId).OwnerId);
  }

  @IsTest
  static void vendedorAnteriorContinuaElegivelNaRotacao() {
    List<Id> vs = montarFila(2);
    Id oppA = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppA });
    Id anterior = vs[0];
    Id atual = opp(oppA).OwnerId;
    // Uma segunda Oportunidade, agora do NOVO dono: o vendedor anterior
    // continua no roster e pode voltar a receber.
    Id oppB = oppVencida(PRODUTO_RT, atual);
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppB });
    Test.stopTest();

    System.assertEquals(
      anterior,
      opp(oppB).OwnerId,
      'O vendedor que perdeu a Opp por prazo permanece na rotação.'
    );
    System.assertEquals(
      2,
      [SELECT COUNT() FROM GroupMember WHERE GroupId IN (SELECT Id FROM Group WHERE DeveloperName = :FILA_SINTETICA)],
      'Ninguém é removido da fila.'
    );
  }

  // ================================================== TASKS

  @IsTest
  static void transfereSomenteTasksAbertas() {
    List<Id> vs = montarFila(2);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    Task aberta1 = tarefa(oppId, vs[0], 'Open', 'Reunião final');
    Task aberta2 = tarefa(oppId, vs[0], 'Open', null);
    Task concluida = tarefa(oppId, vs[0], 'Completed', null);
    Task cancelada = tarefa(oppId, vs[0], 'Cancelada', null);

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    Id novo = opp(oppId).OwnerId;
    System.assertEquals(1, r.reatribuidas);
    System.assertEquals(2, r.tarefasTransferidas, 'Só as duas abertas.');
    System.assertEquals(novo, ownerDaTask(aberta1.Id));
    System.assertEquals(novo, ownerDaTask(aberta2.Id));
    System.assertEquals(vs[0], ownerDaTask(concluida.Id), 'Task concluída intacta.');
    System.assertEquals(vs[0], ownerDaTask(cancelada.Id), 'Task cancelada intacta.');
    System.assertEquals('Completed', [SELECT Status FROM Task WHERE Id = :concluida.Id].Status);
    System.assertEquals('Cancelada', [SELECT Status FROM Task WHERE Id = :cancelada.Id].Status);
  }

  @IsTest
  static void preservaEtapaMarcosEDadosPreenchidos() {
    List<Id> vs = montarFila(2);
    Datetime inicio = Datetime.now().addDays(-60);
    Datetime prazo = Datetime.now().addDays(-1);
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], inicio, prazo, 'Negociação');

    Test.startTest();
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    Test.stopTest();

    Opportunity o = opp(oppId);
    System.assertEquals('Negociação', o.StageName, 'Etapa preservada.');
    System.assertEquals(inicio, o.SOL_Data_Inicio_Ciclo_Comercial__c, 'Início do ciclo preservado.');
    System.assertEquals(prazo, o.SOL_Prazo_Total_Comercial__c, 'Prazo NÃO é reiniciado.');
    System.assertEquals('Valor a recuperar', o.SOL_ECAC_Resultado__c, 'Marcos preservados.');
    System.assertEquals(1000, o.SOL_Valor_Recuperavel__c);
    // Auditoria registrada.
    System.assertEquals(1, o.SOL_Qtd_Reatribuicoes_Prazo__c);
    System.assertEquals('Reatribuido', o.SOL_Status_Reatribuicao_Prazo__c);
    System.assertEquals(SOLPrazoTotalService.MOTIVO_PRAZO_TOTAL, o.SOL_Motivo_Reatribuicao_Prazo__c);
    System.assertNotEquals(null, o.SOL_Data_Reatribuicao_Prazo__c);
    // Nenhuma tarefa nova criada.
    System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :oppId]);
  }

  // ================================================== IDEMPOTÊNCIA / BULK

  @IsTest
  static void umaUnicaVezPorOportunidade() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    Id depoisDaPrimeira = opp(oppId).OwnerId;
    // 2ª e 3ª chamadas (equivalente à varredura diária): nada muda.
    SOLPrazoTotalService.ResultadoPrazoTotal r2 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    SOLPrazoTotalService.ResultadoPrazoTotal r3 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(0, r2.reatribuidas, 'Sem nova troca na varredura seguinte.');
    System.assertEquals(0, r3.reatribuidas);
    System.assertEquals(depoisDaPrimeira, opp(oppId).OwnerId);
    System.assertEquals(1, opp(oppId).SOL_Qtd_Reatribuicoes_Prazo__c);
  }

  @IsTest
  static void batchEhIdempotente() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    Database.executeBatch(new SOLPrazoTotalBatch(), 50);
    Test.stopTest();

    Opportunity o = opp(oppId);
    System.assertNotEquals(vs[0], o.OwnerId, 'O Batch reatribuiu.');
    System.assertEquals(1, o.SOL_Qtd_Reatribuicoes_Prazo__c);

    // Segunda execução (fora do startTest/stopTest, síncrona pelo serviço):
    // a Opp já processada não entra mais.
    Id donoDepois = o.OwnerId;
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    System.assertEquals(donoDepois, opp(oppId).OwnerId, 'Sem nova troca diária.');
  }

  @IsTest
  static void batchNaoRodaComKillSwitchDesligado() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    SOL_Distribuicao_Estado__c estado = [SELECT Id FROM SOL_Distribuicao_Estado__c LIMIT 1];
    update new SOL_Distribuicao_Estado__c(Id = estado.Id, Ativo__c = false);

    Test.startTest();
    Database.executeBatch(new SOLPrazoTotalBatch(), 50);
    Test.stopTest();

    System.assertEquals(vs[0], opp(oppId).OwnerId, 'Kill-switch desligado: nada é tocado.');
  }

  @IsTest
  static void killSwitchDesligadoNoServico() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    SOL_Distribuicao_Estado__c estado = [SELECT Id FROM SOL_Distribuicao_Estado__c LIMIT 1];
    update new SOL_Distribuicao_Estado__c(Id = estado.Id, Ativo__c = false);

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas);
    System.assertEquals(vs[0], opp(oppId).OwnerId);
  }

  @IsTest
  static void processamentoBulk() {
    List<Id> vs = montarFila(4);
    List<Id> opps = new List<Id>();
    for (Integer i = 0; i < 12; i++) {
      opps.add(oppVencida(Math.mod(i, 2) == 0 ? PRODUTO_RT : PRODUTO_ART, vs[Math.mod(i, 4)]));
    }
    // Uma Task aberta por Oportunidade.
    List<Task> tarefas = new List<Task>();
    for (Id oppId : opps) {
      tarefas.add(
        new Task(
          Subject = 't',
          WhatId = oppId,
          OwnerId = UserInfo.getUserId(),
          Status = 'Open',
          ActivityDate = Date.today()
        )
      );
    }
    insert tarefas;

    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(opps);
    Integer soql = Limits.getQueries() - q0;
    Integer dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assertEquals(12, r.reatribuidas, 'Todas reatribuídas em uma passada.');
    System.assertEquals(12, r.tarefasTransferidas);
    System.assertEquals(0, r.comErro);
    // Revisão do PR #15 — a atomicidade por Oportunidade custa SOQL/DML LINEAR
    // (savepoint + update da Opp + consulta e update das Tasks, por Opp). É o
    // tradeoff documentado; o que NÃO pode é escalar de forma quadrática nem
    // estourar os limites de governança. Para 12 Opps: bem abaixo de 100 SOQL /
    // 150 DML. Em produção o Batch roda lote = 1 (uma Opp por transação).
    // (CLICKUP-9438) Os tetos subiram (SOQL 40 -> 48, DML 60 -> 72) porque a
    // ocorrência da jornada entra no MESMO Savepoint de cada Oportunidade — 2
    // consultas e 1 gravação a mais por Opp. Consolidar os eventos fora do laço
    // economizaria consultas e destruiria o isolamento por Oportunidade, que é o
    // motivo de o custo ser linear aqui desde o PR #15.
    System.assert(soql <= 48, 'SOQL linear e contido: ' + soql);
    System.assert(dml <= 72, 'DML linear e contido: ' + dml);
    System.assertEquals(
      12,
      [SELECT COUNT() FROM Opportunity WHERE Id IN :opps AND SOL_Qtd_Reatribuicoes_Prazo__c = 1]
    );
  }

  // ================================================== FORA DE ESCOPO

  @IsTest
  static void outraBUEOutroRecordTypeIgnorados() {
    List<Id> vs = montarFila(3);
    // Sem Record Type SOL.
    Id outraBU = novaOpp(PRODUTO_RT, false, vs[0], Datetime.now().addDays(-60), Datetime.now().addDays(-1), null);
    // Record Type SOL, mas produto fora do escopo.
    Id semProduto = novaOpp(null, true, vs[0], Datetime.now().addDays(-60), Datetime.now().addDays(-1), null);

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ outraBU, semProduto }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas);
    System.assertEquals(2, r.ignoradas);
    System.assertEquals(vs[0], opp(outraBU).OwnerId);
    System.assertEquals(vs[0], opp(semProduto).OwnerId);
  }

  @IsTest
  static void semDataInicialNaoInfereNemReatribui() {
    List<Id> vs = montarFila(3);
    // Sem início e sem prazo: mesmo "antiga", não há inferência por CreatedDate.
    Id semInicio = novaOpp(PRODUTO_RT, true, vs[0], null, null, null);
    // Início presente, prazo não calculado (calendário indisponível na conversão).
    Id semPrazo = novaOpp(PRODUTO_RT, true, vs[0], null, null, null);
    update new Opportunity(
      Id = semPrazo,
      SOL_Data_Inicio_Ciclo_Comercial__c = Datetime.now().addDays(-90)
    );

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ semInicio, semPrazo }
    );
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas);
    System.assertEquals(2, r.ignoradas);
    System.assertEquals(vs[0], opp(semInicio).OwnerId);
    System.assertEquals(vs[0], opp(semPrazo).OwnerId);
    System.assertEquals(null, opp(semPrazo).SOL_Prazo_Total_Comercial__c);
  }

  @IsTest
  static void entradasInvalidasSaoNoOp() {
    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r1 = SOLPrazoTotalService.reatribuirPorPrazoTotal(null);
    SOLPrazoTotalService.ResultadoPrazoTotal r2 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>()
    );
    SOLPrazoTotalService.ResultadoPrazoTotal r3 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ UserInfo.getUserId() } // não é Opportunity
    );
    Test.stopTest();

    System.assertEquals(0, r1.reatribuidas);
    System.assertEquals(0, r2.reatribuidas);
    System.assertEquals(0, r3.reatribuidas);
  }

  // ================================================== ATOMICIDADE

  @IsTest
  static void falhaNaGravacaoNaoDeixaEstadoParcial() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    Task aberta = tarefa(oppId, vs[0], 'Open', null);
    Id estadoAntes = [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1]
      .Ultimo_Usuario__c;

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas, 'Nada foi reatribuído.');
    System.assert(r.comErro > 0, 'A falha é reportada de forma controlada.');
    Opportunity o = opp(oppId);
    System.assertEquals(vs[0], o.OwnerId, 'Proprietário intacto.');
    System.assertEquals(vs[0], ownerDaTask(aberta.Id), 'Task intacta.');
    System.assert(
      o.SOL_Qtd_Reatribuicoes_Prazo__c == null || o.SOL_Qtd_Reatribuicoes_Prazo__c == 0,
      'Auditoria não foi gravada parcialmente.'
    );
    System.assertEquals(
      estadoAntes,
      [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1].Ultimo_Usuario__c,
      'Ponteiro não avançou.'
    );
  }

  @IsTest
  static void duasChamadasNaMesmaTransacaoTrocamUmaVezSo() {
    // Idempotência SEQUENCIAL. A concorrência real é protegida pelo FOR UPDATE
    // no singleton, nas Oportunidades e nas Tasks — não simulável em Apex.
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    Id primeiro = opp(oppId).OwnerId;
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    Test.stopTest();

    System.assertEquals(primeiro, opp(oppId).OwnerId);
    System.assertEquals(1, opp(oppId).SOL_Qtd_Reatribuicoes_Prazo__c);
  }

  /**
   * Blocker 4 — duas Oportunidades em escopos INDEPENDENTES (é assim que o
   * Batch roda: lote = 1, uma transação por Oportunidade). Uma falha na
   * gravação; a outra é reatribuída normalmente. A que falhou não trocou de
   * dono, não teve auditoria parcial e continua elegível para a próxima
   * varredura. O ponteiro global só reflete a troca EFETIVADA.
   */
  @IsTest
  static void loteIsolaFalha_umaReatribuiOutraFalha() {
    List<Id> vs = montarFila(4);
    Id oppOk = oppVencida(PRODUTO_RT, vs[0]);
    Id oppFalha = oppVencida(PRODUTO_ART, vs[1]);
    tarefa(oppFalha, vs[1], 'Open', null);
    Id ponteiroAntes = [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1]
      .Ultimo_Usuario__c;

    Test.startTest();
    // Escopo 1 — transação própria: reatribui normalmente.
    SOLPrazoTotalService.ResultadoPrazoTotal r1 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppOk }
    );
    Id ponteiroDepoisDoOk = [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1]
      .Ultimo_Usuario__c;

    // Escopo 2 — outra transação: a gravação falha (aplicação em somente
    // leitura), resultado controlado, nada é tocado.
    Test.setReadOnlyApplicationMode(true);
    SOLPrazoTotalService.ResultadoPrazoTotal r2 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppFalha }
    );
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    // Escopo 1 — sucesso.
    System.assertEquals(1, r1.reatribuidas, 'Escopo 1: reatribuída.');
    System.assertNotEquals(vs[0], opp(oppOk).OwnerId, 'Escopo 1: trocou de dono.');
    System.assertEquals(1, opp(oppOk).SOL_Qtd_Reatribuicoes_Prazo__c);

    // Escopo 2 — falha isolada.
    System.assert(r2.comErro > 0, 'Escopo 2: falha reportada de forma controlada.');
    System.assertEquals(0, r2.reatribuidas);
    Opportunity f = opp(oppFalha);
    System.assertEquals(vs[1], f.OwnerId, 'Escopo 2: a Opp que falhou NÃO trocou de dono.');
    System.assert(
      f.SOL_Qtd_Reatribuicoes_Prazo__c == null || f.SOL_Qtd_Reatribuicoes_Prazo__c == 0,
      'Escopo 2: sem auditoria parcial — continua elegível para nova varredura.'
    );
    System.assertEquals(
      ponteiroDepoisDoOk,
      [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1].Ultimo_Usuario__c,
      'O ponteiro só reflete a troca efetivada (escopo 1), não a que falhou.'
    );
    System.assertNotEquals(
      ponteiroAntes,
      ponteiroDepoisDoOk,
      'O escopo 1 realmente avançou o ponteiro.'
    );
  }

  /**
   * Blocker 4 — o erro NÃO fica só em System.debug. Quando o serviço devolve
   * comErro > 0, `SOLPrazoTotalBatch.execute()` LANÇA LoteComFalhaException. É
   * essa exceção não capturada em `execute()` que faz a plataforma registrar
   * NumberOfErrors > 0 e ExtendedStatus no AsyncApexJob do lote (visível em
   * Setup ▸ Apex Jobs e por SOQL). Com lote = 1, só a Oportunidade desta
   * transação é revertida; ela volta ao filtro na varredura seguinte.
   */
  @IsTest
  static void batchLancaQuandoServicoReportaErro() {
    List<Id> vs = montarFila(2);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    Test.setReadOnlyApplicationMode(true);
    Boolean lancou = false;
    try {
      // execute() usa apenas o escopo (não o BatchableContext).
      new SOLPrazoTotalBatch()
        .execute(null, new List<Opportunity>{ new Opportunity(Id = oppId) });
    } catch (SOLPrazoTotalBatch.LoteComFalhaException e) {
      lancou = true;
      System.assert(
        e.getMessage().contains('CLICKUP-9424'),
        'A exceção carrega o detalhe do lote: ' + e.getMessage()
      );
    }
    Test.setReadOnlyApplicationMode(false);
    Test.stopTest();

    System.assert(
      lancou,
      'execute() lança quando o serviço reporta comErro > 0 — é o que o AsyncApexJob registra.'
    );
    Opportunity o = opp(oppId);
    System.assertEquals(vs[0], o.OwnerId, 'Nada foi reatribuído.');
    System.assert(
      o.SOL_Qtd_Reatribuicoes_Prazo__c == null || o.SOL_Qtd_Reatribuicoes_Prazo__c == 0,
      'A Opp continua elegível para a próxima varredura.'
    );
  }

  /** Blocker 4 — no caminho feliz, `execute()` NÃO lança (lote sem erro). */
  @IsTest
  static void batchNaoLancaQuandoLoteOk() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    new SOLPrazoTotalBatch()
      .execute(null, new List<Opportunity>{ new Opportunity(Id = oppId) });
    Test.stopTest();

    System.assertNotEquals(vs[0], opp(oppId).OwnerId, 'Lote sem erro: reatribuiu e não lançou.');
    System.assertEquals(1, opp(oppId).SOL_Qtd_Reatribuicoes_Prazo__c);
  }

  // ============================ ATOMICIDADE DO PONTEIRO (revisão final PR #15)

  /**
   * O ponteiro global participa do MESMO Savepoint da Oportunidade. Quando a
   * gravação do ponteiro falha, tudo daquela Oportunidade é desfeito:
   * proprietário, Tasks abertas, auditoria E ponteiro. A contagem fica zerada
   * (segue elegível), o cursor não avança e `comErro > 0` chega ao Batch.
   *
   * A falha é INJETADA (`SOLPrazoTotalService.falharGravacaoDoPonteiro`) porque
   * não há como derrubar só esse DML por dados: `SOL_Distribuicao_Estado__c` não
   * tem Validation Rule nem lookup filter. A injeção é blindada por
   * `Test.isRunningTest()`.
   */
  @IsTest
  static void falhaDoPonteiroDesfazAOportunidadeInteira() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    Task aberta = tarefa(oppId, vs[0], 'Open', null);
    Id ponteiroAntes = [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1]
      .Ultimo_Usuario__c;

    Test.startTest();
    SOLPrazoTotalService.falharGravacaoDoPonteiro = true;
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    SOLPrazoTotalService.falharGravacaoDoPonteiro = false;
    Test.stopTest();

    System.assertEquals(0, r.reatribuidas, 'Nada foi contabilizado como reatribuído.');
    System.assert(r.comErro > 0, 'A falha do ponteiro chega ao Batch como comErro.');

    Opportunity o = opp(oppId);
    System.assertEquals(vs[0], o.OwnerId, 'Proprietário INTACTO.');
    System.assertEquals(vs[0], ownerDaTask(aberta.Id), 'Task aberta INTACTA.');
    System.assertEquals(null, o.SOL_Data_Reatribuicao_Prazo__c, 'Auditoria não gravada.');
    System.assertEquals(null, o.SOL_Status_Reatribuicao_Prazo__c);
    System.assert(
      o.SOL_Qtd_Reatribuicoes_Prazo__c == null || o.SOL_Qtd_Reatribuicoes_Prazo__c == 0,
      'Contagem zerada: a Oportunidade segue elegível para a próxima varredura.'
    );
    System.assertEquals(
      ponteiroAntes,
      [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1].Ultimo_Usuario__c,
      'Ponteiro global INTACTO — nada de "reatribuída mas ponteiro não avançado".'
    );
  }

  /**
   * A falha do ponteiro numa Oportunidade não impede as outras, e o cursor não
   * avança por causa dela: a Oportunidade seguinte usa o mesmo ponto de partida.
   */
  @IsTest
  static void falhaDoPonteiroNaoImpedeAsOutrasOportunidades() {
    List<Id> vs = montarFila(3);
    Id oppFalha = oppVencida(PRODUTO_RT, vs[0]);
    Id oppOk = oppVencida(PRODUTO_ART, vs[0]);

    Test.startTest();
    // Escopo 1 — o ponteiro falha: nada muda nesta Opp.
    SOLPrazoTotalService.falharGravacaoDoPonteiro = true;
    SOLPrazoTotalService.ResultadoPrazoTotal r1 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppFalha }
    );
    // Escopo 2 — sem injeção: reatribui normalmente.
    SOLPrazoTotalService.falharGravacaoDoPonteiro = false;
    SOLPrazoTotalService.ResultadoPrazoTotal r2 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppOk }
    );
    Test.stopTest();

    System.assert(r1.comErro > 0, 'Escopo 1: falha reportada.');
    System.assertEquals(0, r1.reatribuidas);
    System.assertEquals(vs[0], opp(oppFalha).OwnerId, 'A Opp que falhou não trocou de dono.');

    System.assertEquals(1, r2.reatribuidas, 'Escopo 2: reatribuída normalmente.');
    System.assertNotEquals(vs[0], opp(oppOk).OwnerId);
    System.assertEquals(
      opp(oppOk).OwnerId,
      [SELECT Ultimo_Usuario__c FROM SOL_Distribuicao_Estado__c LIMIT 1].Ultimo_Usuario__c,
      'O ponteiro reflete exatamente a única troca efetivada.'
    );
  }

  // ================== CONFIGURAÇÃO DO BATCH (revisão final PR #15)

  /**
   * Roster VAZIO não é mais barreira em `start()`: as Oportunidades vencidas
   * chegam ao serviço e recebem "Sem outro vendedor" — sem troca de
   * proprietário e sem virarem processadas. Antes, `haVendedorDiretoAtivo()`
   * devolvia QueryLocator vazio e a situação ficava invisível.
   */
  @IsTest
  static void batchComRosterVazioRegistraSemOutroVendedor() {
    montarFila(0); // fila válida (habilitada para Lead), sem membro ativo
    Id oppId = oppVencida(PRODUTO_RT, UserInfo.getUserId());

    Test.startTest();
    Id jobId = Database.executeBatch(new SOLPrazoTotalBatch(), SOLPrazoTotalScheduler.TAMANHO_LOTE);
    Test.stopTest();

    AsyncApexJob job = [
      SELECT Status, NumberOfErrors, JobItemsProcessed
      FROM AsyncApexJob
      WHERE Id = :jobId
    ];
    System.assertEquals(0, job.NumberOfErrors, 'Roster vazio é situação controlada, não falha.');
    System.assertEquals(1, job.JobItemsProcessed, 'A Oportunidade vencida CHEGOU ao serviço.');

    Opportunity o = opp(oppId);
    System.assertEquals(UserInfo.getUserId(), o.OwnerId, 'Proprietário não é alterado.');
    System.assertEquals(
      'Sem outro vendedor',
      o.SOL_Status_Reatribuicao_Prazo__c,
      'A situação controlada é registrada, não silenciada.'
    );
    System.assertEquals(SOLPrazoTotalService.MOTIVO_SEM_OUTRO_VENDEDOR, o.SOL_Motivo_Reatribuicao_Prazo__c);
    System.assert(
      o.SOL_Qtd_Reatribuicoes_Prazo__c == null || o.SOL_Qtd_Reatribuicoes_Prazo__c == 0,
      'NÃO é marcada como processada: permite nova tentativa.'
    );
  }

  /** Kill-switch desligado: intencional — nada é tocado e o job não falha. */
  @IsTest
  static void batchComKillSwitchNaoTocaNadaENaoFalha() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    update new SOL_Distribuicao_Estado__c(
      Id = [SELECT Id FROM SOL_Distribuicao_Estado__c LIMIT 1].Id,
      Ativo__c = false
    );

    Test.startTest();
    Id jobId = Database.executeBatch(new SOLPrazoTotalBatch(), SOLPrazoTotalScheduler.TAMANHO_LOTE);
    Test.stopTest();

    AsyncApexJob job = [
      SELECT Status, NumberOfErrors, JobItemsProcessed
      FROM AsyncApexJob
      WHERE Id = :jobId
    ];
    System.assertEquals(0, job.NumberOfErrors, 'Kill-switch não é falha operacional.');
    System.assertEquals(0, job.JobItemsProcessed, 'Nenhum lote executado.');
    System.assertEquals(vs[0], opp(oppId).OwnerId, 'Nada tocado.');
    System.assertEquals(null, opp(oppId).SOL_Status_Reatribuicao_Prazo__c);
  }

  /**
   * Singleton AUSENTE é falha operacional: `start()` lança e o AsyncApexJob
   * registra — nunca termina em silêncio como sucesso.
   */
  @IsTest
  static void batchComSingletonAusenteFalhaOperacional() {
    montarFila(3);
    delete [SELECT Id FROM SOL_Distribuicao_Estado__c];

    // start() não usa o BatchableContext: dá para exercitá-lo direto e assegurar
    // a exceção de forma determinística.
    Boolean lancou = false;
    Test.startTest();
    try {
      new SOLPrazoTotalBatch().start(null);
    } catch (SOLPrazoTotalBatch.ConfiguracaoInvalidaException e) {
      lancou = true;
      System.assert(
        e.getMessage().contains('CLICKUP-9424') && e.getMessage().containsIgnoreCase('singleton'),
        'Mensagem operacional aponta o singleton: ' + e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(lancou, 'Singleton ausente faz start() lançar (o job é marcado como falho).');
  }

  /**
   * Fila ausente / não habilitada para Lead também é falha operacional em
   * `start()` — distinta de "roster vazio", que segue adiante.
   */
  @IsTest
  static void batchComFilaInvalidaFalhaOperacional() {
    // Aponta o serviço para uma fila que não existe.
    SOLDistribuicaoService.queueDeveloperNameOverride = 'RR_Fila_Inexistente_9424';

    Boolean lancou = false;
    Test.startTest();
    try {
      new SOLPrazoTotalBatch().start(null);
    } catch (SOLPrazoTotalBatch.ConfiguracaoInvalidaException e) {
      lancou = true;
      System.assert(
        e.getMessage().containsIgnoreCase('fila'),
        'Mensagem operacional aponta a fila: ' + e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(lancou, 'Fila inválida/ausente faz start() lançar.');
  }

  /** Com singleton, fila e roster válidos, `start()` devolve as vencidas. */
  @IsTest
  static void batchComConfiguracaoValidaSelecionaAsVencidas() {
    List<Id> vs = montarFila(2);
    Id vencida = oppVencida(PRODUTO_RT, vs[0]);
    Id futura = novaOpp(
      PRODUTO_RT,
      true,
      vs[0],
      Datetime.now().addDays(-1),
      Datetime.now().addDays(10),
      null
    );

    Test.startTest();
    Database.QueryLocator ql = new SOLPrazoTotalBatch().start(null);
    Test.stopTest();

    Set<Id> selecionadas = new Set<Id>();
    Database.QueryLocatorIterator it = ql.iterator();
    while (it.hasNext()) {
      selecionadas.add(((Opportunity) it.next()).Id);
    }
    System.assert(selecionadas.contains(vencida), 'A vencida entra na varredura.');
    System.assertEquals(false, selecionadas.contains(futura), 'A que não venceu fica fora.');
  }

  /**
   * Evidência (revisão do PR #15) — "Sem outro vendedor" não é regravado quando
   * status/motivo já estão nesse valor: a varredura seguinte não gera uma
   * gravação idêntica.
   */
  @IsTest
  static void semOutroVendedorNaoRegravaQuandoJaRegistrado() {
    List<Id> vs = montarFila(1); // único vendedor = o próprio dono
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);

    Test.startTest();
    SOLPrazoTotalService.ResultadoPrazoTotal r1 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Datetime gravadoEm1 = [
      SELECT LastModifiedDate
      FROM Opportunity
      WHERE Id = :oppId
    ]
    .LastModifiedDate;

    SOLPrazoTotalService.ResultadoPrazoTotal r2 = SOLPrazoTotalService.reatribuirPorPrazoTotal(
      new List<Id>{ oppId }
    );
    Datetime gravadoEm2 = [
      SELECT LastModifiedDate
      FROM Opportunity
      WHERE Id = :oppId
    ]
    .LastModifiedDate;
    Test.stopTest();

    System.assertEquals(1, r1.semOutroVendedor);
    System.assertEquals(1, r2.semOutroVendedor, 'Continua contabilizando a situação.');
    System.assertEquals(
      'Sem outro vendedor',
      opp(oppId).SOL_Status_Reatribuicao_Prazo__c
    );
    System.assertEquals(
      gravadoEm1,
      gravadoEm2,
      'A 2ª varredura NÃO regrava a Oportunidade (status/motivo já iguais).'
    );
  }

  // ================================================== SCHEDULER

  @IsTest
  static void schedulerAgendaUmaVezEDesagenda() {
    // A org pode JÁ ter o job agendado (runbook). O teste não depende disso e
    // nunca aborta um agendamento pré-existente.
    Boolean jaExistia = ![
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :SOLPrazoTotalScheduler.NOME_JOB
    ]
    .isEmpty();

    Test.startTest();
    if (!jaExistia) {
      System.assertNotEquals(null, SOLPrazoTotalScheduler.agendar(), 'Agendou.');
    }
    // Com o job existente (criado agora ou já presente na org), a chamada
    // seguinte recusa duplicar: agendamento idempotente.
    Boolean recusouDuplicar = false;
    try {
      SOLPrazoTotalScheduler.agendar();
    } catch (SOLPrazoTotalScheduler.AgendamentoException e) {
      recusouDuplicar = true;
    }
    Test.stopTest();

    System.assert(recusouDuplicar, 'Agendamento idempotente: recusa duplicar.');
    List<CronTrigger> gatilhos = [
      SELECT Id, CronExpression, CronJobDetail.Name
      FROM CronTrigger
      WHERE CronJobDetail.Name = :SOLPrazoTotalScheduler.NOME_JOB
    ];
    System.assert(!gatilhos.isEmpty(), 'O job existe com o nome único do card.');

    // Blocker 2 — de HORA EM HORA, no minuto 30; NUNCA diário às 06:30.
    System.assertEquals(
      '0 30 * * * ?',
      SOLPrazoTotalScheduler.CRON_HORARIO,
      'Varredura horária no minuto 30 (uma Opp que vence às 08:00 é pega às 08:30).'
    );
    System.assertEquals(
      '0 30 * * * ?',
      gatilhos[0].CronExpression,
      'O CronTrigger agendado usa a expressão horária.'
    );

    // Nome e horário distintos do job de reprocessamento (minuto 0): não
    // disparam no mesmo instante, não interferem.
    System.assertNotEquals(
      SOLDistribuicaoReprocessamentoScheduler.NOME_JOB,
      SOLPrazoTotalScheduler.NOME_JOB
    );
    System.assertNotEquals(
      SOLDistribuicaoReprocessamentoScheduler.CRON_HORARIO,
      SOLPrazoTotalScheduler.CRON_HORARIO,
      'Minuto 0 (reprocessamento) x minuto 30 (prazo total).'
    );
    System.assert(
      SOLPrazoTotalScheduler.NOME_JOB.containsIgnoreCase('hora em hora'),
      'O nome do job reflete a cadência horária, não "diario".'
    );
    if (!jaExistia) {
      // Só desagenda o que este teste criou.
      SOLPrazoTotalScheduler.desagendar();
    }
  }

  /**
   * Blocker 2 — uma Oportunidade cujo prazo vence na ABERTURA do 30º dia útil
   * (08:00 em São Paulo) entra na PRIMEIRA varredura posterior, sem esperar
   * outro dia. Com o cron no minuto 30, essa varredura é às 08:30 do mesmo dia:
   * o Batch usa `limite = System.now()` e o filtro é `prazo <= limite`.
   */
  @IsTest
  static void oportunidadeQueVenceAsOitoEntraNaVarreduraSeguinte() {
    List<Id> vs = montarFila(3);

    // Prazo = hoje às 08:00 em São Paulo. Instante fixo, no passado do "agora"
    // da varredura (que roda 08:30+).
    Date hojeSP = SOLBusinessHoursHelper.dataEm(System.now(), TZ_SP);
    Datetime venceAsOito = Datetime.newInstance(
      hojeSP.year(),
      hojeSP.month(),
      hojeSP.day(),
      8,
      0,
      0
    );
    // Se o teste rodar antes das 08:30, recua um dia para garantir prazo vencido.
    if (System.now() < venceAsOito.addMinutes(30)) {
      venceAsOito = venceAsOito.addDays(-1);
    }

    Id oppId = novaOpp(
      PRODUTO_RT,
      true,
      vs[0],
      venceAsOito.addDays(-45),
      venceAsOito,
      null
    );

    Test.startTest();
    Database.executeBatch(new SOLPrazoTotalBatch(), SOLPrazoTotalScheduler.TAMANHO_LOTE);
    Test.stopTest();

    Opportunity o = opp(oppId);
    System.assertNotEquals(
      vs[0],
      o.OwnerId,
      'A Opp que venceu às 08:00 foi reatribuída já na varredura seguinte.'
    );
    System.assertEquals(1, o.SOL_Qtd_Reatribuicoes_Prazo__c);
    System.assertEquals(
      venceAsOito,
      o.SOL_Prazo_Total_Comercial__c,
      'O prazo NÃO é recalculado pela varredura.'
    );
  }

  // ================================================== FLS / HISTÓRICO

  /**
   * O QUE ESTE TESTE GARANTE (revisão final do PR #15 — sem exagerar o escopo):
   *  1. a reatribuição por prazo TROCA de proprietário de verdade;
   *  2. o histórico nativo de Opportunity está habilitado e
   *     `OpportunityFieldHistory` é CONSULTÁVEL para `Field = 'Owner'`.
   *
   * O QUE ELE **NÃO** GARANTE: os valores `OldValue`/`NewValue`. A plataforma
   * materializa essas linhas apenas no COMMIT da transação, então dentro de um
   * teste Apex elas normalmente não existem — comprovado também em apex anônimo
   * de uma única transação (0 linhas) contra a mesma troca relida depois
   * (2 linhas: uma por nome, uma por Id). A conferência abaixo é DEFENSIVA: se
   * o runtime materializar as linhas, elas têm de ser coerentes; se não
   * materializar, o teste não finge tê-las validado.
   *
   * A evidência real de `OldValue`/`NewValue` é PÓS-COMMIT e está no E2E
   * (`scripts/apex/e2e_9424.apex`, passo 8).
   */
  @IsTest
  static void historicoDeProprietarioTrocaRealEHistoricoDisponivel() {
    List<Id> vs = montarFila(3);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    Id donoAntes = vs[0];

    Test.startTest();
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    Test.stopTest();

    // (1) Troca real de proprietário — o fato que o histórico nativo registra.
    Id donoDepois = opp(oppId).OwnerId;
    System.assertNotEquals(donoAntes, donoDepois, 'A reatribuição trocou o proprietário.');
    System.assert(new Set<Id>(vs).contains(donoDepois), 'O novo dono é um vendedor da fila.');

    // (2) Histórico habilitado e consultável (a SOQL abaixo não lança).
    System.assert(
      Schema.getGlobalDescribe().containsKey('opportunityfieldhistory'),
      'Histórico nativo de Opportunity habilitado (OpportunityFieldHistory existe).'
    );
    System.assert(
      Opportunity.OwnerId.getDescribe().isAccessible(),
      'OwnerId acessível — é o campo rastreado.'
    );
    List<OpportunityFieldHistory> historico = [
      SELECT Field, OldValue, NewValue
      FROM OpportunityFieldHistory
      WHERE OpportunityId = :oppId AND Field = 'Owner'
    ];

    // Conferência DEFENSIVA (ver o cabeçalho): só roda se a plataforma
    // materializar as linhas dentro da transação de teste.
    for (OpportunityFieldHistory h : historico) {
      System.assertEquals(
        String.valueOf(donoAntes),
        String.valueOf(h.OldValue),
        'Se a linha existir, OldValue é o dono anterior.'
      );
      System.assertEquals(
        String.valueOf(donoDepois),
        String.valueOf(h.NewValue),
        'Se a linha existir, NewValue é o novo dono.'
      );
    }
  }

  /**
   * Acesso ao histórico de proprietário — o que este card ENTREGA e o que
   * DEPENDE da configuração da org (revisão final do PR #15).
   *
   * ENTREGUE pelos permission sets do card: FLS de leitura dos 6 campos
   * técnicos e de `OwnerId` para os dois papéis (ver
   * `flsEfetiva_vendedorEGestor` e `flsDeclaradaNosDoisPermissionSets`).
   *
   * ENTREGUE em nível de REGISTRO: o **vendedor** dono da Oportunidade — a
   * propriedade do registro basta, e é comprovado aqui de verdade.
   *
   * **NÃO entregue por este card:** a visibilidade de registro do **gestor**.
   * `PS_SOL_Distribuicao_Admin` não concede `objectPermissions` de Opportunity
   * (só de `SOL_Distribuicao_Estado__c`) — este teste ASSERE essa ausência para
   * que a dependência fique registrada em código. O gestor enxerga a
   * Oportunidade de outro vendedor pelo perfil + hierarquia de papéis /
   * "Ver todos os dados" já configurados na org, não por este PR. A evidência
   * com um gestor REAL da ArnoneDev está no E2E
   * (`scripts/apex/e2e_9424_historico.apex`, via `UserRecordAccess`) — nenhum
   * permission set sintético é criado aqui para simular esse acesso.
   */
  @IsTest
  static void acessoAoHistoricoDoVendedorDonoEDependenciaDoGestor() {
    List<Id> vs = montarFila(2);
    Id oppId = oppVencida(PRODUTO_RT, vs[0]);
    SOLPrazoTotalService.reatribuirPorPrazoTotal(new List<Id>{ oppId });
    Id donoAtual = opp(oppId).OwnerId;

    Test.startTest();
    // Vendedor DONO: acesso em nível de registro à Opp e ao histórico dela.
    System.runAs(new User(Id = donoAtual)) {
      System.assertEquals(
        1,
        [SELECT COUNT() FROM Opportunity WHERE Id = :oppId],
        'O vendedor dono enxerga a Oportunidade reatribuída para ele.'
      );
      // UserRecordAccess exige RecordId no SELECT — é o runtime confirmando o
      // acesso de LEITURA em nível de registro, não uma inferência do teste.
      List<UserRecordAccess> acesso = [
        SELECT RecordId, HasReadAccess
        FROM UserRecordAccess
        WHERE UserId = :donoAtual AND RecordId = :oppId
      ];
      System.assertEquals(1, acesso.size(), 'UserRecordAccess respondeu para o dono.');
      System.assertEquals(
        true,
        acesso[0].HasReadAccess,
        'Acesso de LEITURA em nível de registro confirmado pelo próprio runtime.'
      );
      // A consulta ao histórico não lança para o dono.
      System.assert(
        [SELECT COUNT() FROM OpportunityFieldHistory WHERE OpportunityId = :oppId] >= 0,
        'O vendedor dono consulta o histórico da própria Oportunidade.'
      );
    }
    Test.stopTest();

    // Dependência registrada: o PS do gestor NÃO dá acesso ao objeto
    // Opportunity — logo o acesso de registro dele vem da hierarquia/perfil.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM ObjectPermissions
        WHERE Parent.Name = 'PS_SOL_Distribuicao_Admin' AND SobjectType = 'Opportunity'
      ],
      'PS_SOL_Distribuicao_Admin não concede objeto Opportunity: a visibilidade de ' +
        'registro do gestor depende de perfil/hierarquia da org, não deste card.'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM ObjectPermissions
        WHERE Parent.Name = 'PS_SOL_Distribuicao_Admin' AND SobjectType = 'SOL_Distribuicao_Estado__c'
      ],
      'O que esse PS concede é o singleton da distribuição.'
    );
  }

  @IsTest
  static void flsEfetiva_vendedorEGestor() {
    User vCom = vendedor('com');
    User vAdm = vendedor('adm');
    System.runAs(contextoAtual()) {
      insert new List<User>{ vCom, vAdm };
      insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(
          AssigneeId = vCom.Id,
          PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SOL_Comercial' LIMIT 1].Id
        ),
        new PermissionSetAssignment(
          AssigneeId = vAdm.Id,
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
    for (User u : new List<User>{ vCom, vAdm }) {
      String papel = u.Id == vCom.Id ? 'PS_SOL_Comercial' : 'PS_SOL_Distribuicao_Admin';
      System.runAs(new User(Id = u.Id)) {
        for (
          Schema.SObjectField f : new List<Schema.SObjectField>{
            Opportunity.SOL_Data_Inicio_Ciclo_Comercial__c,
            Opportunity.SOL_Prazo_Total_Comercial__c,
            Opportunity.SOL_Data_Reatribuicao_Prazo__c,
            Opportunity.SOL_Motivo_Reatribuicao_Prazo__c,
            Opportunity.SOL_Qtd_Reatribuicoes_Prazo__c,
            Opportunity.SOL_Status_Reatribuicao_Prazo__c
          }
        ) {
          Schema.DescribeFieldResult d = f.getDescribe();
          System.assert(d.isAccessible(), papel + ': ' + d.getName() + ' isAccessible.');
          System.assert(
            !d.isUpdateable(),
            papel + ': ' + d.getName() + ' NÃO é isUpdateable (campo técnico).'
          );
        }
      }
    }
    Test.stopTest();
  }

  @IsTest
  static void flsDeclaradaNosDoisPermissionSets() {
    Set<String> campos = new Set<String>{
      'Opportunity.SOL_Data_Inicio_Ciclo_Comercial__c',
      'Opportunity.SOL_Prazo_Total_Comercial__c',
      'Opportunity.SOL_Data_Reatribuicao_Prazo__c',
      'Opportunity.SOL_Motivo_Reatribuicao_Prazo__c',
      'Opportunity.SOL_Qtd_Reatribuicoes_Prazo__c',
      'Opportunity.SOL_Status_Reatribuicao_Prazo__c'
    };
    for (String ps : new List<String>{ 'PS_SOL_Comercial', 'PS_SOL_Distribuicao_Admin' }) {
      Integer vistos = 0;
      for (FieldPermissions fp : [
        SELECT Field, PermissionsRead, PermissionsEdit
        FROM FieldPermissions
        WHERE Parent.Name = :ps AND SobjectType = 'Opportunity' AND Field IN :campos
      ]) {
        vistos++;
        System.assert(fp.PermissionsRead, ps + ' — ' + fp.Field + ' legível.');
        System.assertEquals(false, fp.PermissionsEdit, ps + ' — ' + fp.Field + ' somente leitura.');
      }
      System.assertEquals(6, vistos, ps + ' — os 6 campos técnicos têm FLS declarada.');
    }
  }

  // ================================================== REGRESSÃO

  @IsTest
  static void regressao_distribuicaoEReatribuicaoPorTentativas() {
    List<Id> vs = montarFila(3);

    Test.startTest();
    // CLICKUP-9394: distribuição inicial + Task "1ª Ligação".
    Lead l = new Lead(
      RecordTypeId = rtLeadSOL(),
      LastName = 'Reg ' + rnd(),
      Company = 'C',
      CNPJ__c = CNPJ,
      Status = 'Captação - Contato',
      SOL_Produto_Interesse__c = PRODUTO_ART
    );
    insert l;
    Lead depois = [
      SELECT OwnerId, SOL_Data_Inicio_Ciclo_Contato__c FROM Lead WHERE Id = :l.Id
    ];
    System.assert(new Set<Id>(vs).contains(depois.OwnerId), 'Distribuição inicial intacta.');
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação']
    );

    // CLICKUP-9400: reatribuição por 3 tentativas sem contato.
    insert new List<Task>{
      new Task(WhoId = l.Id, Subject = 'n1', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n2', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu'),
      new Task(WhoId = l.Id, Subject = 'n3', Status = 'Completed', ActivityDate = Date.today(), SOL_Resultado_Contato__c = 'Não atendeu')
    };
    SOLDistribuicaoService.reatribuirPorFaltaDeContato(new List<Id>{ l.Id });
    Test.stopTest();

    System.assertNotEquals(
      depois.OwnerId,
      [SELECT OwnerId FROM Lead WHERE Id = :l.Id].OwnerId,
      'CLICKUP-9400 intacto: reatribuição por falta de contato.'
    );
  }

  @IsTest
  static void regressao_reuniaoFinalEFechamentoIntactos() {
    List<Id> vs = montarFila(2);
    // Opp em Negociação, dentro do prazo: a jornada 9422/9423 segue igual.
    Id oppId = novaOpp(PRODUTO_RT, true, vs[0], Datetime.now().addDays(-1), Datetime.now().addDays(20), 'Negociação');

    Test.startTest();
    // CLICKUP-9422 → 9423: concluir a reunião final cria a tarefa de fechamento.
    Task rf = new Task(
      Subject = 'Realizar reunião final',
      WhatId = oppId,
      OwnerId = vs[0],
      Status = 'Open',
      ActivityDate = Date.today().addDays(3),
      SOL_Tipo_Tarefa__c = 'Reunião final'
    );
    insert rf;
    update new Task(Id = rf.Id, Status = 'Completed', SOL_Data_Reuniao_Final__c = Date.today());
    Test.stopTest();

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhatId = :oppId AND SOL_Tipo_Tarefa__c = 'Fechamento'],
      'CLICKUP-9423 intacto: tarefa de fechamento criada.'
    );
    System.assertEquals('Negociação', opp(oppId).StageName);
    System.assertEquals(
      Datetime.now().addDays(20).date(),
      opp(oppId).SOL_Prazo_Total_Comercial__c.date(),
      'O prazo total não é reiniciado pelas etapas.'
    );
  }
}
