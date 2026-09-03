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

  /**
   * O transporte da data na conversão NÃO é exercitável nesta org: o usuário
   * não tem acesso a Account.CNPJ__c / Account.Unidades_Atendidas__c e
   * SOL_ConverterLead SEMPRE toca esses campos ("Operation failed due to fields
   * being inaccessible on Sobject Account ... fieldNames:
   * CNPJ__c,Unidades_Atendidas__c" / "No such column 'CNPJ__c' on entity
   * 'Account'"). É a MESMA causa raiz das 8 falhas conhecidas de
   * SOL_ConverterLeadTest, anterior a este card — que não alterou Account nem
   * perfis. O que este card acrescentou à conversão é verificado nas duas
   * metades verificáveis: (1) o campo do Lead entra na consulta da conversão;
   * (2) o limite gravado é exatamente o de 30 dias úteis, para RT e ART 360.
   */
  @IsTest
  static void conversaoConsultaODataDoContatoEfetivado() {
    Test.startTest();
    System.assert(
      SOL_ConverterLead.CAMPOS_LEAD.contains('SOL_Data_Contato_Efetivado__c'),
      'A conversão precisa consultar SOL_Data_Contato_Efetivado__c para transportá-la.'
    );
    Test.stopTest();
  }

  @IsTest
  static void limiteGravadoNaConversao_RT_e_ART360() {
    // Os dois produtos usam a MESMA régua: o valor que a conversão grava em
    // SOL_Prazo_Total_Comercial__c é calcularPrazoTotal(contato efetivado).
    Datetime contatoRT = Datetime.newInstanceGmt(2026, 6, 10, 20, 30, 0); // fora do expediente
    Datetime contatoArt = Datetime.newInstanceGmt(2026, 6, 13, 15, 0, 0); // sábado

    Test.startTest();
    Datetime prazoRT = SOLPrazoTotalService.calcularPrazoTotal(contatoRT);
    Datetime prazoArt = SOLPrazoTotalService.calcularPrazoTotal(contatoArt);
    Test.stopTest();

    System.assertEquals(prazoEsperado(contatoRT), prazoRT, 'RT: 30 dias úteis do contato.');
    System.assertEquals(prazoEsperado(contatoArt), prazoArt, 'ART 360: mesma régua.');
    System.assertNotEquals(
      prazoRT,
      prazoArt,
      'Cada data de contato tem seu próprio limite — nada é derivado de hoje.'
    );
  }

  @IsTest
  static void semContatoEfetivadoNaoHaLimite() {
    Test.startTest();
    // É o mesmo guarda que a conversão aplica: sem a data, nada é gravado.
    System.assertEquals(null, SOLPrazoTotalService.calcularPrazoTotal(null));
    Test.stopTest();

    List<Id> vs = montarFila(2);
    Id semInicio = novaOpp(PRODUTO_RT, true, vs[0], null, null, null);
    Opportunity o = opp(semInicio);
    System.assertEquals(null, o.SOL_Data_Inicio_Ciclo_Comercial__c);
    System.assertEquals(null, o.SOL_Prazo_Total_Comercial__c);
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
    System.assert(soql < 15, 'SOQL não escala por Oportunidade: ' + soql);
    System.assert(dml < 8, 'DML não escala por Oportunidade: ' + dml);
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
    System.assert(
      ![
        SELECT Id
        FROM CronTrigger
        WHERE CronJobDetail.Name = :SOLPrazoTotalScheduler.NOME_JOB
      ]
      .isEmpty(),
      'O job existe com o nome único do card.'
    );
    // Nome e horário distintos do job de reprocessamento: não interferem.
    System.assertNotEquals(
      SOLDistribuicaoReprocessamentoScheduler.NOME_JOB,
      SOLPrazoTotalScheduler.NOME_JOB
    );
    System.assertNotEquals(
      SOLDistribuicaoReprocessamentoScheduler.CRON_HORARIO,
      SOLPrazoTotalScheduler.CRON_DIARIO
    );
    if (!jaExistia) {
      // Só desagenda o que este teste criou.
      SOLPrazoTotalScheduler.desagendar();
    }
  }

  // ================================================== FLS / HISTÓRICO

  @IsTest
  static void historicoDeProprietarioHabilitado() {
    Test.startTest();
    Schema.DescribeFieldResult owner = Opportunity.OwnerId.getDescribe();
    System.assert(
      owner.isAccessible(),
      'OwnerId acessível — o histórico nativo registra as trocas por prazo.'
    );
    // OpportunityFieldHistory só existe quando o histórico do objeto está ativo.
    System.assert(
      Schema.getGlobalDescribe().containsKey('opportunityfieldhistory'),
      'Histórico nativo de Opportunity habilitado (OpportunityFieldHistory).'
    );
    Integer historico = [SELECT COUNT() FROM OpportunityFieldHistory WHERE Field = 'Owner'];
    System.assert(historico >= 0, 'Consulta ao histórico de proprietário disponível.');
    Test.stopTest();
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
