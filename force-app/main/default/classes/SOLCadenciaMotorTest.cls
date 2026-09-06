/**
 * CLICKUP-9398 — Testes do MOTOR de repetição diária da cadência de contato SOL.
 *
 * O motor não cria Task, não trata idempotência e não reatribui: tudo isso já
 * tem dono e já tem teste (CLICKUP-9434/9435/9436 e 9400). O que se prova aqui
 * é o que só existe neste card — QUAL dia da cadência é hoje, para quem, e o
 * que acontece nas bordas:
 *
 * - o dia 1 na abertura do ciclo, inclusive quando o ciclo abre à noite, no fim
 *   de semana ou na sexta depois do expediente;
 * - os dias 2 e 3 pelos dias úteis anteriores, e o esgotamento depois deles;
 * - AUSÊNCIA de backfill: só o dia corrente, nunca os dias vencidos;
 * - os três canais no mesmo dia, com o mesmo vencimento, ou nenhum deles;
 * - as condições de parada: dia não útil, kill-switch, calendário ausente,
 *   singleton ausente e Leads inelegíveis;
 * - a entrega dos esgotados ao CLICKUP-9400 sem enfraquecer a exigência de três
 *   resultados negativos.
 *
 * RELÓGIO E CALENDÁRIO — todos os cenários fixam o instante com
 * `SOLCadenciaMotorService.overrideAgora` e ancoram o ciclo do Lead em datas
 * REAIS do calendário comercial da org (seg-qui 08:00-18:00, sex 08:00-17:00,
 * America/Sao_Paulo). Sem isso o resultado dependeria do dia em que a suíte
 * roda — um teste que passa na terça e falha no sábado não prova nada.
 *
 * A grade usada é a semana de 31/08/2026 (segunda) a 06/09/2026 (domingo), com
 * a sexta anterior em 28/08. São datas PASSADAS de propósito: a contagem de
 * tentativas do CLICKUP-9400 compara `CompletedDateTime` (que a plataforma
 * carimba com a hora real) contra o início do ciclo, e um ciclo ancorado no
 * futuro deixaria toda tentativa fora da janela.
 *
 * O Flow SOL_Distribuir_Lead está ATIVO: inserir um Lead SOL distribui de
 * verdade e cria a ligação do dia 1. Os testes usam isso de propósito, com uma
 * fila SINTÉTICA (mesma costura de SOLCadenciaContatoTest), sem desativar
 * automação nenhuma.
 */
@IsTest
private class SOLCadenciaMotorTest {
  private static final String FILA_SINTETICA = 'RR_Motor_SOL_9398';
  private static final String CNPJ = '11222333000181';

  private static final String CANAL_LIGACAO = 'Ligação';
  private static final String CANAL_EMAIL = 'E-mail';
  private static final String CANAL_WHATSAPP = 'WhatsApp';
  private static final List<String> CANAIS = new List<String>{
    CANAL_LIGACAO,
    CANAL_EMAIL,
    CANAL_WHATSAPP
  };

  private static final String TIPO_CONTATO = 'Contato';
  private static final String STATUS_ABERTO = 'Open';
  private static final String STATUS_CONCLUIDO = 'Completed';
  private static final String STATUS_CANCELADA = 'Cancelada';

  private static final String RES_ATENDEU = 'Atendeu';
  private static final String RES_NAO_ATENDEU = 'Não atendeu';
  private static final String RES_ENVIADO = 'Enviado';
  private static final String MOTIVO_CONTATO_EFETIVADO = 'Contato efetivado';
  private static final String MOTIVO_OPT_OUT = 'Opt-out';
  private static final String MOTIVO_PERDA = 'Negócio perdido';
  private static final String PRODUTO_RT = 'Recuperação Tributária';
  private static final String PRODUTO_ART = 'ART 360';

  // Grade fixa do calendário comercial (todas no passado — ver cabeçalho).
  private static final Date SEXTA_ANTERIOR = Date.newInstance(2026, 8, 28);
  private static final Date SABADO_ANTERIOR = Date.newInstance(2026, 8, 29);
  private static final Date SEGUNDA = Date.newInstance(2026, 8, 31);
  private static final Date TERCA = Date.newInstance(2026, 9, 1);
  private static final Date QUARTA = Date.newInstance(2026, 9, 2);
  private static final Date SEXTA = Date.newInstance(2026, 9, 4);
  private static final Date SABADO = Date.newInstance(2026, 9, 5);
  private static final Date DOMINGO = Date.newInstance(2026, 9, 6);

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ============================================================ helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User montarUsuario(String apelido) {
    String unico =
      String.valueOf(Math.abs(Crypto.getRandomInteger())) + apelido;
    return new User(
      FirstName = 'Motor',
      LastName = 'Teste ' + apelido,
      Alias = ('mt' + apelido).left(8),
      Email = 'motor.' + apelido + '@arnone.invalid',
      Username = 'motor.svc.' + unico + '@arnone.clickup9398.test.invalid',
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

  /** Fila sintética com membros diretos ativos; chamar ANTES de inserir Leads. */
  private static Cenario montarCenario(Integer qtdVendedores) {
    Cenario c = new Cenario();
    List<User> criados = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      criados.add(montarUsuario('v' + i));
    }
    System.runAs(contextoAtual()) {
      insert criados;
      Group fila = new Group(
        Name = 'Motor Svc SOL 9398',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      c.filaId = fila.Id;
      List<GroupMember> gms = new List<GroupMember>();
      for (User u : criados) {
        gms.add(new GroupMember(GroupId = c.filaId, UserOrGroupId = u.Id));
      }
      insert gms;
    }
    for (User u : criados) {
      c.vendedores.add(u.Id);
    }
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    return c;
  }

  private static Id rtLead(String devName) {
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

  /** Insere `qtd` Leads SOL — o Flow ativo distribui e cria a ligação do dia 1. */
  private static List<Lead> leadsDistribuidos(Integer qtd) {
    Id rt = rtLead('SOL');
    String st = statusLead();
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < qtd; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rt,
          LastName = 'Lead SOL ' + i,
          Company = 'Empresa ' + i,
          Status = st,
          CNPJ__c = CNPJ
        )
      );
    }
    insert leads;
    List<Lead> distribuidos = [
      SELECT Id, OwnerId, SOL_Data_Inicio_Ciclo_Contato__c
      FROM Lead
      WHERE Id IN :leads
      ORDER BY CreatedDate ASC, Id ASC
    ];
    for (Lead l : distribuidos) {
      System.assertNotEquals(
        null,
        l.SOL_Data_Inicio_Ciclo_Contato__c,
        'Pré-condição: o Lead precisa sair da distribuição com ciclo aberto.'
      );
    }
    return distribuidos;
  }

  /**
   * Instante correspondente a `hora:minuto` em São Paulo, na data `d`.
   *
   * O Brasil não observa horário de verão desde 2019, então o offset é fixo em
   * UTC-3 para as datas de 2026 usadas aqui. `premissaDeFusoDoTesteEstaCorreta`
   * verifica isso contra o próprio helper de produção — se a premissa cair, é lá
   * que o teste avisa, e não com um resultado enigmático em outro cenário.
   */
  private static Datetime emSaoPaulo(Date d, Integer hora, Integer minuto) {
    Datetime meiaNoiteSP = Datetime.newInstanceGmt(
      d,
      Time.newInstance(3, 0, 0, 0)
    );
    return meiaNoiteSP.addMinutes(hora * 60 + minuto);
  }

  /** Fixa o "agora" do motor às 10:00 (São Paulo) da data informada. */
  private static void agoraEm(Date d) {
    SOLCadenciaMotorService.overrideAgora(emSaoPaulo(d, 10, 0));
  }

  private static Lead recarregar(Id leadId) {
    return [
      SELECT
        Id,
        OwnerId,
        SOL_Data_Inicio_Ciclo_Contato__c,
        SOL_Contato_Efetivado__c,
        SOL_Opt_Out__c,
        Status,
        SOL_Quantidade_Reatribuicoes__c
      FROM Lead
      WHERE Id = :leadId
    ];
  }

  /**
   * Lead distribuído, com o ciclo REANCORADO em `ciclo` e SEM as tarefas do
   * ciclo de distribuição — o cenário limpo de "este Lead está no ciclo X".
   * As tarefas do ciclo antigo não atrapalhariam a chave (o ciclo entra nela),
   * mas atrapalhariam a leitura das asserções.
   */
  private static Lead leadNoCiclo(Datetime ciclo) {
    Lead l = leadsDistribuidos(1)[0];
    delete [SELECT Id FROM Task WHERE WhoId = :l.Id];
    update new Lead(Id = l.Id, SOL_Data_Inicio_Ciclo_Contato__c = ciclo);
    return recarregar(l.Id);
  }

  /** Tarefas da cadência de um Lead, opcionalmente filtradas por canal e dia. */
  private static List<Task> tarefas(Id leadId, String canal, Integer dia) {
    List<Task> filtradas = new List<Task>();
    for (Task t : [
      SELECT
        Id,
        Subject,
        WhoId,
        OwnerId,
        Status,
        ActivityDate,
        SOL_Prazo_Contato__c,
        SOL_Tipo_Tarefa__c,
        SOL_Canal_Contato__c,
        SOL_Dia_Cadencia__c,
        SOL_Ciclo_Contato__c,
        SOL_Resultado_Contato__c,
        SOL_Resultado_Envio__c,
        SOL_Motivo_Cancelamento__c
      FROM Task
      WHERE WhoId = :leadId AND SOL_Tipo_Tarefa__c = :TIPO_CONTATO
      ORDER BY SOL_Dia_Cadencia__c ASC, SOL_Canal_Contato__c ASC
    ]) {
      Boolean canalOk = canal == null || t.SOL_Canal_Contato__c == canal;
      Boolean diaOk =
        dia == null ||
        (t.SOL_Dia_Cadencia__c != null &&
        t.SOL_Dia_Cadencia__c.intValue() == dia);
      if (canalOk && diaOk) {
        filtradas.add(t);
      }
    }
    return filtradas;
  }

  private static Integer quantasNoDia(Id leadId, Integer dia) {
    return tarefas(leadId, null, dia).size();
  }

  private static SOLCadenciaMotorService.ResultadoMotor rodar(List<Id> ids) {
    return SOLCadenciaMotorService.executar(ids);
  }

  private static SOLCadenciaMotorService.ResultadoMotor rodar(Id leadId) {
    return rodar(new List<Id>{ leadId });
  }

  /** Conclui uma ligação com resultado negativo — a tentativa que o 9400 conta. */
  private static void concluirLigacaoNegativa(Id leadId, Id ownerId) {
    insert new Task(
      Subject = 'Tentativa',
      WhoId = leadId,
      OwnerId = ownerId,
      Status = STATUS_CONCLUIDO,
      SOL_Tipo_Tarefa__c = TIPO_CONTATO,
      SOL_Canal_Contato__c = CANAL_LIGACAO,
      SOL_Resultado_Contato__c = RES_NAO_ATENDEU
    );
  }

  // ============================================== premissas do próprio teste

  /**
   * A grade de datas e o auxiliar de fuso batem com o helper de produção? Este
   * teste existe para que uma mudança de fuso (ou uma data escrita errada)
   * apareça AQUI, e não como um dia de cadência inexplicável em outro cenário.
   */
  @IsTest
  static void premissaDeFusoDoTesteEstaCorreta() {
    Id bhId = SOLBusinessHoursHelper.businessHoursId();
    System.assertNotEquals(
      null,
      bhId,
      'Business Hours "Arnone Soluções - Horário Comercial" é pré-requisito.'
    );

    Test.startTest();
    for (Date d : new List<Date>{ SEXTA_ANTERIOR, SEGUNDA, QUARTA, DOMINGO }) {
      System.assertEquals(
        d,
        SOLBusinessHoursHelper.dataEm(
          emSaoPaulo(d, 10, 0),
          SOLBusinessHoursHelper.TZ_SAO_PAULO
        ),
        'O auxiliar de fuso do teste precisa cair no dia certo em São Paulo: ' + d
      );
      // Meia-noite e 23h do mesmo dia continuam no mesmo dia em São Paulo.
      System.assertEquals(
        d,
        SOLBusinessHoursHelper.dataEm(
          emSaoPaulo(d, 23, 0),
          SOLBusinessHoursHelper.TZ_SAO_PAULO
        ),
        'Às 23h de São Paulo ainda é o mesmo dia: ' + d
      );
    }
    for (Date util : new List<Date>{ SEXTA_ANTERIOR, SEGUNDA, TERCA, QUARTA, SEXTA }) {
      System.assert(
        SOLBusinessHoursHelper.ehDiaUtil(bhId, util),
        'Dia útil na grade do teste: ' + util
      );
    }
    for (Date naoUtil : new List<Date>{ SABADO_ANTERIOR, SABADO, DOMINGO }) {
      System.assert(
        !SOLBusinessHoursHelper.ehDiaUtil(bhId, naoUtil),
        'Fim de semana não é dia útil: ' + naoUtil
      );
    }
    Test.stopTest();
  }

  // ==================================================== dias 1, 2 e 3

  /** (1) Dia 1: os TRÊS canais, com o vencimento do dia corrente. */
  @IsTest
  static void diaUmAcionaOsTresCanaisComOVencimentoDeHoje() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(1, r.leadsNoDia, 'Um Lead no dia corrente.');
    System.assertEquals(1, r.leadsPorDia.get(1), 'E ele está no dia 1.');
    System.assertEquals(0, r.leadsEsgotados, 'Não está esgotado.');
    System.assertEquals(3, r.tarefasCriadas, 'Uma tarefa por canal.');
    System.assertEquals(0, r.tarefasJaExistentes, 'Nenhuma já existia.');
    System.assertEquals(0, r.comErro, 'Sem falha.');

    for (String canal : CANAIS) {
      List<Task> ts = tarefas(l.Id, canal, 1);
      System.assertEquals(1, ts.size(), 'Exatamente uma tarefa no canal ' + canal);
      Task t = ts[0];
      System.assertEquals(l.Id, t.WhoId, 'Vinculada ao Lead.');
      System.assertEquals(l.OwnerId, t.OwnerId, 'Do proprietário do ciclo.');
      System.assertEquals(STATUS_ABERTO, t.Status, 'Nasce aberta.');
      System.assertEquals(
        emSaoPaulo(QUARTA, 9, 0),
        t.SOL_Ciclo_Contato__c,
        'Carrega o ciclo vigente do Lead.'
      );
      System.assertEquals(
        null,
        t.SOL_Resultado_Contato__c,
        'O motor não preenche resultado de ligação.'
      );
      System.assertEquals(
        null,
        t.SOL_Resultado_Envio__c,
        'Nem resultado de envio: quem preenche é o vendedor.'
      );
    }

    // E-mail e WhatsApp vencem HOJE; a ligação do dia 1 é a única que deriva a
    // data do prazo de 5 minutos úteis — regra do núcleo, preservada.
    for (String canal : new List<String>{ CANAL_EMAIL, CANAL_WHATSAPP }) {
      Task t = tarefas(l.Id, canal, 1)[0];
      System.assertEquals(QUARTA, t.ActivityDate, canal + ' vence no dia corrente.');
      System.assertEquals(
        null,
        t.SOL_Prazo_Contato__c,
        canal + ' não tem SLA em minutos úteis.'
      );
    }
    System.assertNotEquals(
      null,
      tarefas(l.Id, CANAL_LIGACAO, 1)[0].SOL_Prazo_Contato__c,
      'A ligação do dia 1 mantém o prazo de 5 minutos úteis.'
    );
  }

  /** (2) Dias 2 e 3 saem dos dias úteis anteriores, com vencimento de hoje. */
  @IsTest
  static void diasDoisETresSaemDosDiasUteisAnteriores() {
    montarCenario(2);
    Lead noDia2 = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    Lead noDia3 = leadNoCiclo(emSaoPaulo(SEGUNDA, 9, 0));
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(
      new List<Id>{ noDia2.Id, noDia3.Id }
    );
    Test.stopTest();

    System.assertEquals(2, r.leadsNoDia, 'Os dois Leads estão em dia ativo.');
    System.assertEquals(0, r.leadsPorDia.get(1), 'Nenhum no dia 1.');
    System.assertEquals(1, r.leadsPorDia.get(2), 'Um no dia 2.');
    System.assertEquals(1, r.leadsPorDia.get(3), 'Um no dia 3.');
    System.assertEquals(6, r.tarefasCriadas, '2 Leads × 3 canais.');

    Map<Id, Integer> diaEsperado = new Map<Id, Integer>{
      noDia2.Id => 2,
      noDia3.Id => 3
    };
    for (Id leadId : diaEsperado.keySet()) {
      Integer dia = diaEsperado.get(leadId);
      System.assertEquals(
        3,
        quantasNoDia(leadId, dia),
        'Os três canais do dia ' + dia + '.'
      );
      System.assertEquals(
        3,
        tarefas(leadId, null, null).size(),
        'E NADA além do dia corrente — sem backfill dos dias vencidos.'
      );
      for (Task t : tarefas(leadId, null, dia)) {
        System.assertEquals(
          QUARTA,
          t.ActivityDate,
          'Todo canal do dia ' + dia + ' vence hoje, inclusive a ligação.'
        );
        System.assertEquals(
          null,
          t.SOL_Prazo_Contato__c,
          'Fora do dia 1 nenhum canal tem prazo em minutos.'
        );
      }
    }
  }

  /**
   * (3) SEM BACKFILL — um Lead que chega ao dia 3 sem nunca ter recebido os
   * dias 1 e 2 (job parado, por exemplo) recebe SÓ o dia 3. Tarefa vencida não
   * é criada retroativamente.
   */
  @IsTest
  static void naoCriaOsDiasVencidosQueOMotorPerdeu() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(SEGUNDA, 9, 0));
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(3, r.tarefasCriadas, 'Só o dia corrente é criado.');
    System.assertEquals(0, quantasNoDia(l.Id, 1), 'O dia 1 vencido NÃO é criado.');
    System.assertEquals(0, quantasNoDia(l.Id, 2), 'O dia 2 vencido NÃO é criado.');
    System.assertEquals(3, quantasNoDia(l.Id, 3), 'Apenas o dia 3, de hoje.');
  }

  /**
   * (4) Ciclo aberto FORA do expediente: o dia 1 é a próxima abertura útil, não
   * o dia do relógio. Ciclo na terça às 22h ⇒ dia 1 na quarta.
   */
  @IsTest
  static void cicloAbertoDeNoiteComecaNaProximaAberturaUtil() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(TERCA, 22, 0));
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(
      1,
      r.leadsPorDia.get(1),
      'Ciclo aberto depois do expediente começa no dia útil seguinte: quarta é o DIA 1.'
    );
    System.assertEquals(0, r.leadsPorDia.get(2), 'E não o dia 2.');
    System.assertEquals(3, quantasNoDia(l.Id, 1), 'Os três canais do dia 1.');
  }

  /** (4) Ciclo aberto no SÁBADO começa na segunda. */
  @IsTest
  static void cicloAbertoNoFimDeSemanaComecaNaSegunda() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(SABADO_ANTERIOR, 12, 0));
    agoraEm(SEGUNDA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(
      1,
      r.leadsPorDia.get(1),
      'Sábado não conta: a segunda é o dia 1.'
    );
    System.assertEquals(3, quantasNoDia(l.Id, 1), 'Os três canais do dia 1.');
  }

  /** (4) Sexta ⇒ o dia 2 cai na segunda, pulando o fim de semana. */
  @IsTest
  static void cicloNaSextaTemODiaDoisNaSegunda() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(SEXTA_ANTERIOR, 10, 0));
    agoraEm(SEGUNDA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(
      1,
      r.leadsPorDia.get(2),
      'O dia útil seguinte a uma sexta é a segunda: dia 2.'
    );
    System.assertEquals(3, quantasNoDia(l.Id, 2), 'Os três canais do dia 2.');
    System.assertEquals(0, quantasNoDia(l.Id, 1), 'Sem backfill do dia 1.');
  }

  /** (5) Sábado e domingo: o motor não executa. */
  @IsTest
  static void naoExecutaEmDiaSemExpediente() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(SEXTA, 10, 0));

    Test.startTest();
    agoraEm(SABADO);
    SOLCadenciaMotorService.ResultadoMotor rSabado = rodar(l.Id);
    agoraEm(DOMINGO);
    SOLCadenciaMotorService.ResultadoMotor rDomingo = rodar(l.Id);
    Test.stopTest();

    for (SOLCadenciaMotorService.ResultadoMotor r : new List<SOLCadenciaMotorService.ResultadoMotor>{
      rSabado,
      rDomingo
    }) {
      System.assert(r.diaNaoUtil, 'O motor reconhece o dia sem expediente.');
      System.assertEquals(0, r.tarefasCriadas, 'E não cria nada.');
      System.assertEquals(0, r.leadsNoDia, 'Nenhum Lead entra em dia ativo.');
      System.assertEquals(0, r.leadsEsgotados, 'E ninguém é avaliado para troca.');
    }
    System.assertEquals(
      0,
      tarefas(l.Id, null, null).size(),
      'Nenhuma tarefa de cadência no fim de semana.'
    );
  }

  /**
   * (6) A data de referência é a de SÃO PAULO. Às 23h de quarta em São Paulo o
   * servidor já está na quinta em UTC — usar a data do GMT adiantaria a cadência
   * inteira em um dia.
   */
  @IsTest
  static void aDataDeReferenciaEhADeSaoPauloNaoADoGmt() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    // 02:00 GMT de quinta = 23:00 de quarta em São Paulo.
    SOLCadenciaMotorService.overrideAgora(
      Datetime.newInstanceGmt(2026, 9, 3, 2, 0, 0)
    );

    Test.startTest();
    System.assertEquals(
      QUARTA,
      SOLCadenciaMotorService.dataDeReferencia(),
      'Às 23h de São Paulo ainda é quarta.'
    );
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(
      1,
      r.leadsPorDia.get(1),
      'Continua sendo o DIA 1 — o fuso do servidor não adianta a cadência.'
    );
    System.assertEquals(
      QUARTA,
      tarefas(l.Id, CANAL_EMAIL, 1)[0].ActivityDate,
      'E o vencimento é a data de São Paulo.'
    );
  }

  // ==================================================== idempotência

  /** (7) A ligação do dia 1 que a distribuição criou não é duplicada. */
  @IsTest
  static void ligacaoDoDiaUmJaCriadaPelaDistribuicaoNaoDuplica() {
    montarCenario(1);
    // Sem apagar as tarefas: o ciclo permanece o da distribuição, e a "1ª
    // Ligação" que ela criou é, formalmente, a ligação do dia 1 deste ciclo.
    Lead l = leadsDistribuidos(1)[0];
    System.assertEquals(
      1,
      tarefas(l.Id, CANAL_LIGACAO, 1).size(),
      'Pré-condição: a distribuição já criou a ligação do dia 1.'
    );
    agoraEm(QUARTA);
    update new Lead(
      Id = l.Id,
      SOL_Data_Inicio_Ciclo_Contato__c = emSaoPaulo(QUARTA, 9, 0)
    );
    // A tarefa da distribuição carrega o ciclo antigo; para provar a
    // idempotência, ela é realinhada ao ciclo vigente — é o mesmo estado de um
    // Lead distribuído hoje de manhã.
    Task daDistribuicao = tarefas(l.Id, CANAL_LIGACAO, 1)[0];
    daDistribuicao.SOL_Ciclo_Contato__c = emSaoPaulo(QUARTA, 9, 0);
    update daDistribuicao;

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(
      2,
      r.tarefasCriadas,
      'Só e-mail e WhatsApp são criados: a ligação do dia 1 já existia.'
    );
    System.assertEquals(
      1,
      r.tarefasJaExistentes,
      'A ligação existente é absorvida pela idempotência do núcleo.'
    );
    System.assertEquals(
      1,
      tarefas(l.Id, CANAL_LIGACAO, 1).size(),
      'Continua havendo UMA ligação no dia 1.'
    );
    System.assertEquals(
      daDistribuicao.Id,
      tarefas(l.Id, CANAL_LIGACAO, 1)[0].Id,
      'E é a mesma tarefa: nada foi recriado.'
    );
  }

  /** (7) Reexecutar na mesma janela é inofensivo — retry idempotente. */
  @IsTest
  static void reexecutarNaMesmaJanelaNaoCriaNadaNovo() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor primeira = rodar(l.Id);
    SOLCadenciaMotorService.ResultadoMotor segunda = rodar(l.Id);
    SOLCadenciaMotorService.ResultadoMotor terceira = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(3, primeira.tarefasCriadas, 'A primeira cria os 3 canais.');
    System.assertEquals(0, segunda.tarefasCriadas, 'A segunda não cria nada.');
    System.assertEquals(3, segunda.tarefasJaExistentes, 'Os 3 já existiam.');
    System.assertEquals(0, terceira.tarefasCriadas, 'Nem a terceira.');
    System.assertEquals(
      3,
      tarefas(l.Id, null, null).size(),
      'O Lead segue com exatamente três tarefas.'
    );
  }

  /**
   * (7) Um Lead atribuído DEPOIS da varredura anterior recebe o dia 1 na
   * varredura seguinte — é o mecanismo que garante que o dia 1 não se perde,
   * sem acoplar a distribuição ao motor.
   */
  @IsTest
  static void leadAtribuidoDepoisDaVarreduraAnteriorRecebeODiaUm() {
    montarCenario(2);
    Lead antigo = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    agoraEm(QUARTA);
    SOLCadenciaMotorService.ResultadoMotor primeira = rodar(antigo.Id);
    System.assertEquals(3, primeira.tarefasCriadas, 'Pré-condição: a 1ª varredura rodou.');

    // Só agora chega o Lead novo, já dentro do expediente de hoje.
    Lead novo = leadNoCiclo(emSaoPaulo(QUARTA, 9, 30));

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor segunda = rodar(
      new List<Id>{ antigo.Id, novo.Id }
    );
    Test.stopTest();

    System.assertEquals(
      1,
      segunda.leadsPorDia.get(1),
      'O Lead recém-atribuído entra no dia 1 na varredura seguinte.'
    );
    System.assertEquals(3, quantasNoDia(novo.Id, 1), 'Com os três canais.');
    System.assertEquals(
      3,
      segunda.tarefasCriadas,
      'E só ele gera criação: o Lead antigo já estava atendido.'
    );
    System.assertEquals(
      3,
      segunda.tarefasJaExistentes,
      'As três do Lead antigo são absorvidas.'
    );
  }

  // ==================================================== esgotamento (9400)

  /**
   * (8) Passado o dia 3, o motor para de criar e entrega o Lead ao CLICKUP-9400.
   * SEM três resultados negativos aquela avaliação é NO-OP: o Lead não troca de
   * dono, o ciclo não é reiniciado e ele continua elegível.
   */
  @IsTest
  static void esgotadoSemTresNegativasEhAvaliadoENadaMuda() {
    montarCenario(2);
    Lead l = leadNoCiclo(emSaoPaulo(SEXTA_ANTERIOR, 9, 0));
    Id donoOriginal = l.OwnerId;
    Datetime cicloOriginal = l.SOL_Data_Inicio_Ciclo_Contato__c;
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(1, r.leadsEsgotados, 'O Lead passou do dia 3.');
    System.assertEquals(0, r.leadsNoDia, 'E não está em nenhum dia ativo.');
    System.assertEquals(0, r.tarefasCriadas, 'Depois do dia 3 não se cria mais nada.');
    System.assertEquals(0, r.reatribuidos, 'Sem três negativas, ninguém troca de vendedor.');
    System.assertEquals(0, r.comErro, 'E isso não é erro: é no-op.');

    Lead depois = recarregar(l.Id);
    System.assertEquals(donoOriginal, depois.OwnerId, 'O dono é o mesmo.');
    System.assertEquals(
      cicloOriginal,
      depois.SOL_Data_Inicio_Ciclo_Contato__c,
      'E o ciclo não foi reiniciado — o motor não força reatribuição.'
    );
    System.assertEquals(
      0,
      tarefas(l.Id, null, null).size(),
      'Nenhuma tarefa de cadência.'
    );
  }

  /**
   * (8) Com as três negativas exigidas pelo CLICKUP-9400, o esgotamento leva à
   * troca de vendedor — e é aquele serviço, não o motor, quem cria a ligação do
   * dia 1 do novo ciclo.
   */
  @IsTest
  static void esgotadoComTresNegativasEhReatribuidoPeloServicoDo9400() {
    Cenario c = montarCenario(2);
    Lead l = leadsDistribuidos(1)[0];
    // As três negativas já disparam o Flow do CLICKUP-9400 na hora — é o
    // caminho normal, e ele reinicia o ciclo. Só DEPOIS dele o cenário é
    // ancorado no passado, o que devolve as três tentativas à janela do ciclo
    // vigente: é exatamente o estado de um Lead que esgotou a cadência sem que
    // ninguém tenha concluído a última tarefa a tempo.
    for (Integer i = 0; i < 3; i++) {
      concluirLigacaoNegativa(l.Id, l.OwnerId);
    }
    Lead aposFlow = recarregar(l.Id);
    Id donoOriginal = aposFlow.OwnerId;
    delete [
      SELECT Id
      FROM Task
      WHERE WhoId = :l.Id AND SOL_Dia_Cadencia__c != NULL
    ];
    update new Lead(
      Id = l.Id,
      SOL_Data_Inicio_Ciclo_Contato__c = emSaoPaulo(SEXTA_ANTERIOR, 9, 0)
    );
    Datetime cicloOriginal = emSaoPaulo(SEXTA_ANTERIOR, 9, 0);
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    Test.stopTest();

    System.assertEquals(1, r.leadsEsgotados, 'Esgotado.');
    System.assertEquals(1, r.reatribuidos, 'E reatribuído — as três negativas existem.');
    System.assertEquals(0, r.tarefasCriadas, 'O motor não criou tarefa nenhuma.');

    Lead depois = recarregar(l.Id);
    System.assertNotEquals(donoOriginal, depois.OwnerId, 'Trocou de vendedor.');
    System.assert(
      c.vendedores.contains(depois.OwnerId),
      'O novo dono sai da mesma fila.'
    );
    System.assertNotEquals(
      cicloOriginal,
      depois.SOL_Data_Inicio_Ciclo_Contato__c,
      'E o ciclo foi reiniciado pelo serviço da reatribuição.'
    );
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Task
        WHERE
          WhoId = :l.Id
          AND SOL_Canal_Contato__c = :CANAL_LIGACAO
          AND SOL_Dia_Cadencia__c = 1
          AND Status = :STATUS_ABERTO
      ],
      'A ligação do dia 1 do novo ciclo é criada por quem reatribuiu, não pelo motor.'
    );
  }

  // ==================================================== condições de parada

  /** (9) Kill-switch compartilhado com a distribuição desliga o motor. */
  @IsTest
  static void killSwitchDesligadoNaoCriaNadaENaoReatribui() {
    montarCenario(2);
    Lead ativo = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    Lead esgotado = leadNoCiclo(emSaoPaulo(SEXTA_ANTERIOR, 9, 0));
    Id donoDoEsgotado = esgotado.OwnerId;
    agoraEm(QUARTA);

    // O switch é desligado ANTES das tentativas, senão o Flow do CLICKUP-9400
    // reatribuiria na hora da terceira e o cenário nunca chegaria ao motor. Com
    // ele desligado, nem aquele caminho nem este fazem nada — que é o ponto.
    SOL_Distribuicao_Estado__c estado = [
      SELECT Id, Ativo__c
      FROM SOL_Distribuicao_Estado__c
      LIMIT 1
    ];
    estado.Ativo__c = false;
    update estado;
    for (Integer i = 0; i < 3; i++) {
      concluirLigacaoNegativa(esgotado.Id, donoDoEsgotado);
    }

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(
      new List<Id>{ ativo.Id, esgotado.Id }
    );
    Test.stopTest();

    System.assert(r.desligado, 'O motor reconhece o kill-switch desligado.');
    System.assertEquals(0, r.tarefasCriadas, 'Nada é criado.');
    System.assertEquals(0, r.reatribuidos, 'E ninguém é reatribuído.');
    System.assertEquals(
      2,
      r.leadsIgnorados,
      'Os dois Leads são ignorados, sem erro.'
    );
    System.assertEquals(
      0,
      tarefas(ativo.Id, null, null).size(),
      'O Lead do dia corrente não recebeu tarefa.'
    );
    System.assertEquals(
      donoDoEsgotado,
      recarregar(esgotado.Id).OwnerId,
      'E o esgotado continua com o mesmo vendedor.'
    );
  }

  /** (9) Calendário ausente falha VISÍVEL — nunca com fallback silencioso. */
  @IsTest
  static void calendarioAusenteFalhaSemFallback() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    agoraEm(QUARTA);
    SOLBusinessHoursHelper.overrideBusinessHours(null);

    Test.startTest();
    String erro = '';
    try {
      rodar(l.Id);
      System.assert(false, 'Sem calendário o motor tem de LANÇAR, não seguir adiante.');
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      erro = e.getMessage();
    }
    Test.stopTest();

    System.assert(
      erro.contains('calendário'),
      'A falha nomeia o calendário ausente. Recebido: ' + erro
    );
    System.assertEquals(
      0,
      tarefas(l.Id, null, null).size(),
      'E nada foi criado por suposição de data.'
    );
  }

  /** (9) Singleton ausente é falha operacional, não "nada a fazer". */
  @IsTest
  static void singletonAusenteFalhaVisivel() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    agoraEm(QUARTA);
    delete [SELECT Id FROM SOL_Distribuicao_Estado__c];

    Test.startTest();
    String erro = '';
    try {
      rodar(l.Id);
      System.assert(false, 'Sem o singleton o motor tem de LANÇAR.');
    } catch (SOLCadenciaMotorService.ConfiguracaoInvalidaException e) {
      erro = e.getMessage();
    }
    Test.stopTest();

    System.assert(
      erro.contains('singleton'),
      'A falha nomeia o singleton. Recebido: ' + erro
    );
  }

  /** (9) Lista nula/vazia não toca no banco. */
  @IsTest
  static void listaNulaOuVaziaNaoConsultaNada() {
    agoraEm(QUARTA);

    Test.startTest();
    Integer antes = Limits.getQueries();
    SOLCadenciaMotorService.ResultadoMotor nulo = rodar((List<Id>) null);
    SOLCadenciaMotorService.ResultadoMotor vazio = rodar(new List<Id>());
    Integer delta = Limits.getQueries() - antes;
    Test.stopTest();

    System.assertEquals(0, nulo.tarefasCriadas, 'Nulo: nada criado.');
    System.assertEquals(0, vazio.tarefasCriadas, 'Vazio: nada criado.');
    System.assertEquals(0, delta, 'E nenhuma consulta é gasta.');
  }

  /** (10) Todas as inelegibilidades num único lote — ignoradas, sem erro. */
  @IsTest
  static void inelegiveisSaoIgnoradosNoMesmoLote() {
    Cenario c = montarCenario(2);
    Lead elegivel = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    Lead semCiclo = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    update new Lead(Id = semCiclo.Id, SOL_Data_Inicio_Ciclo_Contato__c = null);
    Lead naFila = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    update new Lead(Id = naFila.Id, OwnerId = c.filaId);
    Lead efetivado = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    update new Lead(Id = efetivado.Id, SOL_Contato_Efetivado__c = true);
    Lead optOut = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    update new Lead(
      Id = optOut.Id,
      SOL_Opt_Out__c = true,
      SOL_Motivo_Desqualificacao__c = MOTIVO_OPT_OUT
    );
    Lead perdido = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    update new Lead(
      Id = perdido.Id,
      Status = 'Desqualificado',
      SOL_Motivo_Desqualificacao__c = MOTIVO_PERDA
    );
    Lead outraBU = new Lead(
      LastName = 'Fora',
      Company = 'Outra BU',
      Status = statusLead(),
      SOL_Data_Inicio_Ciclo_Contato__c = emSaoPaulo(QUARTA, 9, 0)
    );
    insert outraBU;
    Lead apagado = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    Id idApagado = apagado.Id;
    delete apagado;
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(
      new List<Id>{
        elegivel.Id,
        semCiclo.Id,
        naFila.Id,
        efetivado.Id,
        optOut.Id,
        perdido.Id,
        outraBU.Id,
        idApagado
      }
    );
    Test.stopTest();

    System.assertEquals(1, r.leadsNoDia, 'Só o Lead elegível entra no dia.');
    System.assertEquals(7, r.leadsIgnorados, 'As sete inelegibilidades são ignoradas.');
    System.assertEquals(0, r.comErro, 'Ignorar não é erro.');
    System.assertEquals(3, r.tarefasCriadas, 'Três canais, um Lead.');
    System.assertEquals(
      3,
      [SELECT COUNT() FROM Task WHERE SOL_Tipo_Tarefa__c = :TIPO_CONTATO],
      'E em nenhum outro Lead da org.'
    );
  }

  // ==================================================== atomicidade

  /**
   * (11) Se um canal falha, NENHUM canal fica gravado — nem para o Lead que
   * causou a falha, nem para os outros do mesmo lote. O gatilho aqui é um Lead
   * cujo proprietário foi desativado: `Task.OwnerId` recusa usuário inativo, e a
   * recusa derruba o insert do lote inteiro daquele canal.
   */
  @IsTest
  static void falhaDeUmCanalNaoDeixaODiaPelaMetade() {
    Cenario c = montarCenario(2);
    Lead bom = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    Lead problema = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    // Dois vendedores distintos, para que só o segundo Lead fique com um dono
    // inativo. Se a distribuição tiver dado o mesmo dono aos dois, o cenário
    // ainda vale: o lote inteiro falha do mesmo jeito.
    System.runAs(contextoAtual()) {
      update new User(Id = problema.OwnerId, IsActive = false);
    }
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(
      new List<Id>{ bom.Id, problema.Id }
    );
    Test.stopTest();

    System.assert(r.comErro > 0, 'A falha é reportada, não engolida.');
    System.assertEquals(0, r.tarefasCriadas, 'E nada é contabilizado como criado.');
    System.assert(
      !r.mensagens.isEmpty(),
      'Com mensagem controlada para o operador.'
    );
    System.assertEquals(
      0,
      tarefas(bom.Id, null, null).size(),
      'O Lead saudável do lote também não fica com tarefa: sem criação parcial.'
    );
    System.assertEquals(
      0,
      tarefas(problema.Id, null, null).size(),
      'E o Lead problemático, muito menos.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE SOL_Tipo_Tarefa__c = :TIPO_CONTATO],
      'Nenhum canal sobreviveu ao rollback — nem ligação, nem e-mail, nem WhatsApp.'
    );
  }

  // ==================================================== bulk

  /** (12) Lote grande: consultas e DML não escalam com o tamanho. */
  @IsTest
  static void loteNaoEscalaConsultasNemDml() {
    montarCenario(2);
    List<Lead> leads = leadsDistribuidos(8);
    List<Id> um = new List<Id>();
    List<Id> lote = new List<Id>();
    for (Integer i = 0; i < leads.size(); i++) {
      delete [SELECT Id FROM Task WHERE WhoId = :leads[i].Id];
      update new Lead(
        Id = leads[i].Id,
        SOL_Data_Inicio_Ciclo_Contato__c = emSaoPaulo(TERCA, 9, 0)
      );
      if (i == 0) {
        um.add(leads[i].Id);
      } else {
        lote.add(leads[i].Id);
      }
    }
    agoraEm(QUARTA);
    SOLBusinessHoursHelper.businessHoursId();

    Test.startTest();
    Integer qA = Limits.getQueries();
    Integer dA = Limits.getDmlStatements();
    SOLCadenciaMotorService.ResultadoMotor rUm = rodar(um);
    Integer qUm = Limits.getQueries() - qA;
    Integer dUm = Limits.getDmlStatements() - dA;

    qA = Limits.getQueries();
    dA = Limits.getDmlStatements();
    SOLCadenciaMotorService.ResultadoMotor rLote = rodar(lote);
    Integer qLote = Limits.getQueries() - qA;
    Integer dLote = Limits.getDmlStatements() - dA;
    Test.stopTest();

    System.assertEquals(3, rUm.tarefasCriadas, 'Um Lead, três canais.');
    System.assertEquals(21, rLote.tarefasCriadas, '7 Leads × 3 canais.');
    System.assertEquals(qUm, qLote, 'As consultas não escalam com o lote.');
    System.assertEquals(dUm, dLote, 'E o DML também não.');
    for (Id leadId : lote) {
      System.assertEquals(3, quantasNoDia(leadId, 2), 'Cada Lead recebeu o dia 2.');
    }
  }

  // ==================================================== Batch e Scheduler

  /** (13) O Batch varre os Leads com ciclo aberto e ignora o resto. */
  @IsTest
  static void batchVarreOsLeadsComCicloAberto() {
    Cenario c = montarCenario(2);
    Lead noDia1 = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    Lead noDia2 = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    Lead efetivado = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    update new Lead(Id = efetivado.Id, SOL_Contato_Efetivado__c = true);
    agoraEm(QUARTA);

    Test.startTest();
    Database.executeBatch(new SOLCadenciaMotorBatch(), 50);
    Test.stopTest();

    System.assertEquals(3, quantasNoDia(noDia1.Id, 1), 'O Lead do dia 1 foi atendido.');
    System.assertEquals(3, quantasNoDia(noDia2.Id, 2), 'O do dia 2 também.');
    System.assertEquals(
      0,
      tarefas(efetivado.Id, null, null).size(),
      'E o Lead com contato efetivado ficou de fora do escopo.'
    );
  }

  /** (13) Em dia sem expediente o Batch não toca em Lead nenhum. */
  @IsTest
  static void batchNaoVarreEmDiaSemExpediente() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(SEXTA, 10, 0));
    agoraEm(DOMINGO);

    Test.startTest();
    Database.executeBatch(new SOLCadenciaMotorBatch(), 50);
    Test.stopTest();

    System.assertEquals(
      0,
      tarefas(l.Id, null, null).size(),
      'Domingo: o escopo do Batch é vazio, nada é criado.'
    );
  }

  /** (13) Kill-switch desligado esvazia o escopo do Batch. */
  @IsTest
  static void batchComKillSwitchDesligadoTemEscopoVazio() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    agoraEm(QUARTA);
    SOL_Distribuicao_Estado__c estado = [
      SELECT Id, Ativo__c
      FROM SOL_Distribuicao_Estado__c
      LIMIT 1
    ];
    estado.Ativo__c = false;
    update estado;

    Test.startTest();
    Database.executeBatch(new SOLCadenciaMotorBatch(), 50);
    Test.stopTest();

    System.assertEquals(
      0,
      tarefas(l.Id, null, null).size(),
      'Com o kill-switch desligado o Batch não cria nada.'
    );
  }

  /** (13) Sem singleton, o Batch falha de forma visível já no start. */
  @IsTest
  static void batchSemSingletonFalhaNoStart() {
    delete [SELECT Id FROM SOL_Distribuicao_Estado__c];

    Test.startTest();
    String erro = '';
    try {
      new SOLCadenciaMotorBatch().start(null);
      System.assert(false, 'O start tem de lançar sem o singleton.');
    } catch (SOLCadenciaMotorService.ConfiguracaoInvalidaException e) {
      erro = e.getMessage();
    }
    Test.stopTest();

    System.assert(erro.contains('singleton'), 'Nomeando o singleton. Recebido: ' + erro);
  }

  /** (13) Sem calendário, o Batch falha de forma visível já no start. */
  @IsTest
  static void batchSemCalendarioFalhaNoStart() {
    SOLBusinessHoursHelper.overrideBusinessHours(null);

    Test.startTest();
    String erro = '';
    try {
      new SOLCadenciaMotorBatch().start(null);
      System.assert(false, 'O start tem de lançar sem calendário.');
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      erro = e.getMessage();
    }
    Test.stopTest();

    System.assert(
      erro.contains('calendário'),
      'Nomeando o calendário. Recebido: ' + erro
    );
  }

  /**
   * (14) O agendamento é único e no minuto 15.
   *
   * `CronTrigger` NÃO é isolado pelo contexto de teste: o SOQL abaixo enxerga
   * os jobs REAIS da org. Depois do deploy o motor fica agendado, então este
   * teste nunca pode assumir que a primeira chamada vai conseguir agendar — se
   * assumisse, passaria só enquanto a org estivesse sem o job e quebraria em
   * todo `RunLocalTests` seguinte. Mesmo padrão (e mesmo cuidado de NÃO tocar o
   * job real) de `SOLDistribuicaoReprocessamentoTest.naoCriaAgendamentoDuplicado`.
   */
  @IsTest
  static void schedulerNaoCriaAgendamentoDuplicado() {
    Boolean jaExiste = ![
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :SOLCadenciaMotorScheduler.NOME_JOB
    ]
    .isEmpty();

    Test.startTest();
    Boolean recusouDuplicado = false;
    try {
      Id primeiro = SOLCadenciaMotorScheduler.agendar();
      System.assert(!jaExiste, 'Só agenda se ainda não existia na org.');
      System.assertNotEquals(null, primeiro, 'O job foi criado.');
      // Agora existe: a próxima chamada tem de recusar.
      try {
        SOLCadenciaMotorScheduler.agendar();
      } catch (SOLCadenciaMotorScheduler.AgendamentoException e) {
        recusouDuplicado = true;
      }
    } catch (SOLCadenciaMotorScheduler.AgendamentoException e) {
      // Já existia na org: a 1ª chamada recusou — o mesmo comportamento correto.
      recusouDuplicado = true;
      System.assert(jaExiste, 'A recusa só é legítima quando o job já existia.');
    }
    // Lido pelo NOME, não pelo Id: nos dois caminhos existe exatamente um job
    // com esse nome, tenha ele sido criado aqui ou já estivesse na org.
    CronTrigger ct = [
      SELECT CronExpression
      FROM CronTrigger
      WHERE CronJobDetail.Name = :SOLCadenciaMotorScheduler.NOME_JOB
      LIMIT 1
    ];
    Test.stopTest();

    System.assert(
      recusouDuplicado,
      'agendar() nunca pode criar um 2º job com o mesmo nome.'
    );
    System.assertEquals(
      '0 15 * * * ?',
      ct.CronExpression,
      'Minuto 15: não colide com o minuto 0 (9394) nem com o 30 (9424).'
    );
    System.assertEquals(
      SOLCadenciaMotorScheduler.CRON_HORARIO,
      ct.CronExpression,
      'E é exatamente a constante publicada pela própria classe.'
    );
  }

  /** (14) Desagendar remove e nunca lança, mesmo repetido. */
  @IsTest
  static void desagendarNaoFalhaEEhIdempotente() {
    // Alterações de agendamento feitas em teste são revertidas ao fim — mesmo
    // padrão de `SOLDistribuicaoReprocessamentoTest`.
    Test.startTest();
    SOLCadenciaMotorScheduler.desagendar();
    SOLCadenciaMotorScheduler.desagendar();
    Test.stopTest();

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name = :SOLCadenciaMotorScheduler.NOME_JOB
      ],
      'Depois de desagendar não sobra job com esse nome, e chamar duas vezes não lança.'
    );
  }

  /**
   * (14) Sobreposição: com um lote da varredura ainda em andamento, a janela
   * seguinte é PULADA em vez de enfileirar uma segunda passagem.
   */
  @IsTest
  static void jobNaoSeSobrepoe() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(QUARTA, 9, 0));
    agoraEm(QUARTA);

    // `AsyncApexJob` também não é isolado pelo contexto de teste: a contagem
    // enxerga os lotes REAIS da org. Por isso o teste mede o DELTA em vez de
    // exigir que a org esteja limpa — exigir isso seria a mesma dependência de
    // estado que quebrou o teste do agendamento.
    Integer lotesAntes = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'BatchApex' AND ApexClass.Name = 'SOLCadenciaMotorBatch'
    ];

    Test.startTest();
    Database.executeBatch(new SOLCadenciaMotorBatch(), 50);
    System.assert(
      SOLCadenciaMotorScheduler.haExecucaoEmAndamento(),
      'Com o lote enfileirado, a próxima janela reconhece a execução em andamento.'
    );
    // O agendador, nesse estado, não dispara uma segunda varredura.
    new SOLCadenciaMotorScheduler().execute(null);
    Integer lotesDepois = [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE JobType = 'BatchApex' AND ApexClass.Name = 'SOLCadenciaMotorBatch'
    ];
    Test.stopTest();

    System.assertEquals(
      lotesAntes + 1,
      lotesDepois,
      'O agendador pulou a janela: um lote a mais, não dois.'
    );
    System.assertEquals(
      3,
      quantasNoDia(l.Id, 1),
      'E a varredura que rodou fez o seu trabalho.'
    );
  }

  // ==================================================== produtos e regressões

  /** (15) Recuperação Tributária e ART 360 se comportam igual. */
  @IsTest
  static void osDoisProdutosSeComportamIgual() {
    montarCenario(2);
    Lead rt = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    Lead art = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    update new List<Lead>{
      new Lead(Id = rt.Id, SOL_Produto_Interesse__c = PRODUTO_RT),
      new Lead(Id = art.Id, SOL_Produto_Interesse__c = PRODUTO_ART)
    };
    agoraEm(QUARTA);

    Test.startTest();
    SOLCadenciaMotorService.ResultadoMotor r = rodar(
      new List<Id>{ rt.Id, art.Id }
    );
    Test.stopTest();

    System.assertEquals(6, r.tarefasCriadas, 'Os dois produtos recebem os três canais.');
    for (Id leadId : new List<Id>{ rt.Id, art.Id }) {
      System.assertEquals(3, quantasNoDia(leadId, 2), 'Mesmo dia, mesmos canais.');
      for (Task t : tarefas(leadId, null, 2)) {
        System.assertEquals(QUARTA, t.ActivityDate, 'Mesmo vencimento.');
      }
    }
  }

  /**
   * (16) Regressão 9435/9436: as tarefas de mensagem criadas pelo motor exigem
   * o resultado do ENVIO para concluir e recusam o resultado de LIGAÇÃO — a
   * separação que mantém e-mail e WhatsApp fora dos gatilhos de contato
   * efetivado, opt-out e reatribuição.
   */
  @IsTest
  static void tarefasDeMensagemDoMotorMantemAsDuasRegras() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    agoraEm(QUARTA);
    rodar(l.Id);

    Test.startTest();
    Map<String, String> errosConclusao = new Map<String, String>();
    Map<String, String> errosResultado = new Map<String, String>();
    for (String canal : new List<String>{ CANAL_EMAIL, CANAL_WHATSAPP }) {
      Id tarefaId = tarefas(l.Id, canal, 2)[0].Id;
      try {
        update new Task(Id = tarefaId, Status = STATUS_CONCLUIDO);
        errosConclusao.put(canal, '');
      } catch (DmlException e) {
        errosConclusao.put(canal, e.getMessage());
      }
      try {
        update new Task(Id = tarefaId, SOL_Resultado_Contato__c = RES_ATENDEU);
        errosResultado.put(canal, '');
      } catch (DmlException e) {
        errosResultado.put(canal, e.getMessage());
      }
    }
    Test.stopTest();

    for (String canal : errosConclusao.keySet()) {
      System.assert(
        errosConclusao.get(canal).contains('resultado do envio'),
        canal + ' não conclui sem resultado do envio. Recebido: ' + errosConclusao.get(canal)
      );
      System.assert(
        errosResultado.get(canal).contains('Resultado do envio'),
        canal + ' recusa o resultado de LIGAÇÃO. Recebido: ' + errosResultado.get(canal)
      );
    }
    System.assert(
      recarregar(l.Id).SOL_Contato_Efetivado__c != true,
      'E nada disso sinalizou contato efetivado no Lead.'
    );
  }

  /**
   * (16) Regressão 9417/9418/9425: as tarefas criadas pelo motor são
   * `SOL_Tipo_Tarefa__c = "Contato"`, então herdam o cancelamento automático
   * sem uma linha de código nova.
   */
  @IsTest
  static void contatoEfetivadoCancelaTudoQueOMotorCriou() {
    montarCenario(1);
    Lead l = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    agoraEm(QUARTA);
    SOLCadenciaMotorService.ResultadoMotor r = rodar(l.Id);
    System.assertEquals(3, r.tarefasCriadas, 'Pré-condição: os três canais do dia 2.');

    Test.startTest();
    Task ligacao = tarefas(l.Id, CANAL_LIGACAO, 2)[0];
    ligacao.SOL_Resultado_Contato__c = RES_ATENDEU;
    ligacao.Status = STATUS_CONCLUIDO;
    update ligacao;
    Test.stopTest();

    System.assertEquals(
      true,
      recarregar(l.Id).SOL_Contato_Efetivado__c,
      'Pré-condição: o contato foi efetivado pela ligação.'
    );
    for (String canal : new List<String>{ CANAL_EMAIL, CANAL_WHATSAPP }) {
      Task t = tarefas(l.Id, canal, 2)[0];
      System.assertEquals(
        STATUS_CANCELADA,
        t.Status,
        'A tarefa de ' + canal + ' pendente é cancelada.'
      );
      System.assertEquals(
        MOTIVO_CONTATO_EFETIVADO,
        t.SOL_Motivo_Cancelamento__c,
        'Com o motivo da automação existente.'
      );
    }
  }

  /**
   * (16) Regressão 9400: concluir os canais de MENSAGEM não conta como
   * tentativa. Três envios registrados mais uma ligação negativa continuam
   * somando UMA tentativa — o vendedor não troca.
   */
  @IsTest
  static void enviosDoMotorNaoContamComoTentativaDeContato() {
    montarCenario(3);
    Lead l = leadNoCiclo(emSaoPaulo(TERCA, 9, 0));
    Id donoOriginal = l.OwnerId;
    agoraEm(QUARTA);
    rodar(l.Id);

    Test.startTest();
    for (String canal : new List<String>{ CANAL_EMAIL, CANAL_WHATSAPP }) {
      Task t = tarefas(l.Id, canal, 2)[0];
      t.SOL_Resultado_Envio__c = RES_ENVIADO;
      t.Status = STATUS_CONCLUIDO;
      update t;
    }
    Task ligacao = tarefas(l.Id, CANAL_LIGACAO, 2)[0];
    ligacao.SOL_Resultado_Contato__c = RES_NAO_ATENDEU;
    ligacao.Status = STATUS_CONCLUIDO;
    update ligacao;
    Test.stopTest();

    Lead depois = recarregar(l.Id);
    System.assertEquals(
      donoOriginal,
      depois.OwnerId,
      'Uma tentativa negativa não reatribui — os envios não somam à contagem.'
    );
    System.assert(
      depois.SOL_Quantidade_Reatribuicoes__c == null ||
      depois.SOL_Quantidade_Reatribuicoes__c == 0,
      'O contador de reatribuições não se move.'
    );
  }

  // ==================================================== função de calendário

  /**
   * (17) O mapeamento dia-a-dia, isolado das dependências: dado hoje e os dois
   * dias úteis anteriores, cada início de ciclo cai no dia certo — e o que é
   * mais antigo que o dia 3 é esgotamento, não dia 4.
   */
  @IsTest
  static void mapeamentoDoDiaCobreAsQuatroSituacoes() {
    Id bhId = SOLBusinessHoursHelper.businessHoursId();
    List<Date> anteriores = new List<Date>{ TERCA, SEGUNDA };

    Test.startTest();
    Integer dia1 = SOLCadenciaMotorService.diaDaCadencia(
      bhId,
      emSaoPaulo(QUARTA, 9, 0),
      QUARTA,
      anteriores
    );
    Integer dia2 = SOLCadenciaMotorService.diaDaCadencia(
      bhId,
      emSaoPaulo(TERCA, 9, 0),
      QUARTA,
      anteriores
    );
    Integer dia3 = SOLCadenciaMotorService.diaDaCadencia(
      bhId,
      emSaoPaulo(SEGUNDA, 9, 0),
      QUARTA,
      anteriores
    );
    Integer esgotado = SOLCadenciaMotorService.diaDaCadencia(
      bhId,
      emSaoPaulo(SEXTA_ANTERIOR, 9, 0),
      QUARTA,
      anteriores
    );
    Integer aindaNaoComecou = SOLCadenciaMotorService.diaDaCadencia(
      bhId,
      emSaoPaulo(QUARTA, 22, 0),
      QUARTA,
      anteriores
    );
    Integer semCiclo = SOLCadenciaMotorService.diaDaCadencia(
      bhId,
      null,
      QUARTA,
      anteriores
    );
    Test.stopTest();

    System.assertEquals(1, dia1, 'Ciclo aberto hoje, no expediente: dia 1.');
    System.assertEquals(2, dia2, 'Ciclo do dia útil anterior: dia 2.');
    System.assertEquals(3, dia3, 'Ciclo de dois dias úteis atrás: dia 3.');
    System.assertEquals(
      SOLCadenciaMotorService.ULTIMO_DIA + 1,
      esgotado,
      'Mais antigo que o dia 3: esgotado.'
    );
    System.assertEquals(
      null,
      aindaNaoComecou,
      'Ciclo aberto hoje às 22h começa amanhã: ainda não há dia ativo.'
    );
    System.assertEquals(null, semCiclo, 'Sem ciclo não há dia.');
  }
}
