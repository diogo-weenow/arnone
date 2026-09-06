/**
 * CLICKUP-9350 — Conversão do Lead da Arnone Soluções em Conta, Contato e
 * Oportunidade.
 *
 * O gatilho de negócio é a entrega da procuração assinada. A conversão é uma
 * ação explícita e guiada, disparada pelo botão "Converter lead" na tela do
 * Lead, que roda o flow SOL_Converter_Lead. O flow só conduz a conversa com o
 * usuário; a regra vive aqui, onde fica versionada e coberta por teste.
 *
 * Por que Apex e não a conversão padrão: a sondagem do PASSO 1 mostrou que, sem
 * código, a conversão cria Conta nova mesmo com CNPJ idêntico, não leva o CNPJ
 * para a Conta, e cria a Oportunidade sem record type — fora do Funil_SOL. E a
 * ação "Convert Lead" do Flow não é alternativa: o InvocableActionType
 * 'convertLead' é recusado pelo schema de metadados desta org, o mesmo motivo
 * já registrado em STE_ConverterLead.
 *
 * O que a plataforma já resolve e por isso não está aqui: o arquivo da
 * procuração é religado sozinho a Conta, Contato e Oportunidade na conversão.
 */
public with sharing class SOL_ConverterLead {
  @TestVisible
  private static final String RT_LEAD = 'SOL';
  @TestVisible
  private static final String RT_OPORTUNIDADE = 'SOL';
  @TestVisible
  private static final String ETAPA_NASCIMENTO = 'Oportunidade Criada';
  @TestVisible
  private static final String ETAPA_RECUPERACAO = 'Diagnóstico';
  @TestVisible
  private static final String ETAPA_ART = 'Negociação';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  public static final String PRODUTO_ART = 'ART 360';
  @TestVisible
  private static final String UNIDADE = 'SOL';

  public static final String SEM_PERMISSAO = 'Você não tem acesso aos campos da Arnone Soluções. Peça ao administrador o conjunto de permissões "Arnone Soluções — Comercial" antes de usar esta ação.';

  // CLICKUP-9424 — se o Lead tem contato efetivado registrado, o prazo total de
  // 30 dias úteis é obrigatório na Oportunidade. Sem o calendário "Arnone
  // Soluções - Horário Comercial" ativo não há como calcular esse limite, e
  // deixar a Oportunidade nascer sem ele quebra a reatribuição automática. A
  // conversão é abortada por inteiro — nada de Lead convertido pela metade.
  public static final String CALENDARIO_INDISPONIVEL = 'A conversão foi cancelada: o calendário "Arnone Soluções - Horário Comercial" está inativo ou ausente, e sem ele não é possível calcular o prazo comercial de 30 dias úteis a partir do contato efetivado. Peça ao administrador para reativar o calendário e converta o lead de novo — nenhum registro foi criado.';

  public static final String CAMPOS_LEAD =
    'Id, Name, FirstName, LastName, Company, Email, Phone, IsConverted, ' +
    'CNPJ__c, RecordType.DeveloperName, SOL_Produto_Interesse__c, ' +
    'SOL_Status_Procuracao__c, SOL_Data_Recebimento_Procuracao__c, ' +
    'SOL_Apto_Conversao__c, SOL_Data_Contato_Efetivado__c, ' +
    // CLICKUP-9439 / CLICKUP-9429 (absorvido) — medicao por etapa. Sao
    // transportados para a Oportunidade na conversao; ver avancarOportunidade.
    'SOL_Data_Primeira_Ligacao__c, SOL_Data_Reuniao_Procuracao__c, ' +
    'SOL_Dias_Primeira_Ligacao__c, SOL_Dias_Contato_Efetivado__c, ' +
    'SOL_Dias_Reuniao_Procuracao__c, SOL_Duracao_Pendente__c, ' +
    'SOL_Duracao_Pendencia_Motivo__c, SOL_Duracao_Pendencia_Detalhe__c';

  // CLICKUP-9439 — SOL_Data_Distribuicao__c fica DE FORA da projeção acima, e
  // isso não é esquecimento. Esta consulta é DINÂMICA, e SOQL dinâmico resolve
  // o nome do campo com a FLS de quem está executando: para um usuário sem
  // PS_SOL_Distribuicao_Admin — que é o caso de todo o Comercial — o campo
  // "não existe" e a consulta lança QueryException, que o catch abaixo
  // transforma em SEM_PERMISSAO. Incluí-la ali quebraria a CONVERSÃO INTEIRA
  // para o time comercial, disfarçada de falta de acesso. Medido em Apex
  // anônimo antes de escrever esta linha.
  //
  // O espelho é lido por SOLDuracaoEtapaService.distribuicaoDeLeads, e NEM
  // MESMO em SOQL estático dentro desta classe: consultar o campo aqui faz a
  // plataforma re-resolver a query em tempo de execução para quem não o enxerga,
  // e a conversão passa a falhar com "Variable does not exist: tmpVar1" — foi o
  // que aconteceu, medido em teste, antes de a leitura ser movida para o
  // serviço, que já lê esse campo em todas as suas consultas.

  // ------------------------------------------------- regras compartilhadas
  //
  // Ficam aqui, e não na classe de preparação, porque são os mesmos portões
  // aplicados duas vezes: uma para a tela decidir o que perguntar, outra na
  // hora de converter, quando não dá para confiar que a tela foi respeitada.
  /**
   * Portões da conversão, iguais para todos os produtos da unidade desde
   * 25/08/2026: procuração recebida e arquivo anexado. Antes o produto decidia
   * qual portão valia, e ART 360 entrava pelo checkbox do atendente.
   */
  public static String impedimentoPara(Lead l, Integer arquivos) {
    if (l.IsConverted) {
      return 'Este lead já foi convertido.';
    }
    if (l.RecordType.DeveloperName != RT_LEAD) {
      return 'Este lead não é da Arnone Soluções. Esta ação só vale para o funil da unidade.';
    }
    if (String.isBlank(l.SOL_Produto_Interesse__c)) {
      return 'Informe o produto de interesse no lead. É ele que decide o portão da conversão e a etapa em que a Oportunidade nasce.';
    }
    // A Conta é pessoa jurídica e o CNPJ é a identidade dela: sem o número não
    // há como saber se o cliente já é atendido por outra unidade, e a conversão
    // criaria uma duplicata silenciosa.
    if (String.isBlank(l.CNPJ__c)) {
      return 'Informe o CNPJ no lead antes de converter. É por ele que a ação encontra uma Conta já existente e evita duplicata.';
    }
    // Desde 25/08/2026 a procuração vale para todos os produtos da unidade.
    // Antes só Recuperação Tributária passava por aqui, e ART 360 entrava pelo
    // checkbox de liberação — que deixou de ser porta de entrada.
    if (l.SOL_Status_Procuracao__c != 'Recebida') {
      return 'A procuração ainda não foi recebida. A entrega do documento assinado é o gatilho da conversão — use a ação "Procuração (e-CAC)" antes desta.';
    }
    if (arquivos == 0) {
      return 'A procuração está marcada como recebida, mas não há arquivo anexado ao lead. Anexe o documento assinado antes de converter.';
    }
    return null;
  }

  public static String resumoDe(Lead l, Integer arquivos) {
    // Todo produto passa pela procuração, então o resumo é o mesmo para todos.
    return l.SOL_Produto_Interesse__c +
      ' · procuração recebida' +
      (l.SOL_Data_Recebimento_Procuracao__c == null
        ? ''
        : ' em ' + l.SOL_Data_Recebimento_Procuracao__c.format()) +
      ' · ' +
      arquivos +
      ' arquivo(s) anexado(s)' +
      ' · CNPJ ' +
      l.CNPJ__c;
  }

  public static Map<Id, Integer> arquivosPorLead(Set<Id> leadIds) {
    Map<Id, Integer> contagem = new Map<Id, Integer>();
    for (ContentDocumentLink cdl : [
      SELECT LinkedEntityId
      FROM ContentDocumentLink
      WHERE LinkedEntityId IN :leadIds
    ]) {
      Integer atual = contagem.get(cdl.LinkedEntityId);
      contagem.put(cdl.LinkedEntityId, atual == null ? 1 : atual + 1);
    }
    return contagem;
  }

  /**
   * Procura a Conta pelo CNPJ sem pontuação: o mesmo número é digitado
   * "11.222.333/0001-81" numa unidade e "11222333000181" em outra, e comparar
   * texto cru acharia duas empresas onde existe uma. As regras de duplicidade
   * padrão não cobrem isto — elas casam por nome e endereço.
   */
  public static Account contaPorCnpj(String cnpj) {
    Set<String> variantes = variantesDe(cnpj);
    if (variantes.isEmpty()) {
      return null;
    }
    List<Account> achadas = [
      SELECT Id, Name, CNPJ__c, Unidades_Atendidas__c
      FROM Account
      WHERE CNPJ__c IN :variantes
      ORDER BY CreatedDate ASC
      LIMIT 1
    ];
    return achadas.isEmpty() ? null : achadas[0];
  }

  /**
   * As duas grafias possíveis do mesmo CNPJ, mais o que veio digitado. Comparar
   * com todas em SOQL é o que permite filtrar no banco; varrer as Contas em
   * Apex para normalizar uma a uma estouraria o limite de linhas assim que a
   * base crescer.
   */
  public static Set<String> variantesDe(String cnpj) {
    Set<String> variantes = new Set<String>();
    String digitos = apenasDigitos(cnpj);
    if (String.isBlank(digitos)) {
      return variantes;
    }
    variantes.add(cnpj.trim());
    variantes.add(digitos);
    if (digitos.length() == 14) {
      variantes.add(
        digitos.substring(0, 2) +
          '.' +
          digitos.substring(2, 5) +
          '.' +
          digitos.substring(5, 8) +
          '/' +
          digitos.substring(8, 12) +
          '-' +
          digitos.substring(12, 14)
      );
    }
    return variantes;
  }

  /** Contato da conta que parece ser a mesma pessoa do lead. */
  public static Contact contatoDaConta(Id contaId, Lead l) {
    List<Contact> porEmail = String.isBlank(l.Email)
      ? new List<Contact>()
      : [
          SELECT Id, Name, Email
          FROM Contact
          WHERE AccountId = :contaId AND Email = :l.Email
          LIMIT 1
        ];
    if (!porEmail.isEmpty()) {
      return porEmail[0];
    }
    List<Contact> porNome = [
      SELECT Id, Name, Email
      FROM Contact
      WHERE AccountId = :contaId AND LastName = :l.LastName
      LIMIT 1
    ];
    return porNome.isEmpty() ? null : porNome[0];
  }

  private static String apenasDigitos(String valor) {
    return valor == null ? null : valor.replaceAll('[^0-9]', '');
  }

  // ---------------------------------------------------------------- conversão

  /** O que a tela devolve depois que o usuário decidiu conta e contato. */
  public class Pedido {
    @InvocableVariable(label='Id do Lead' required=true)
    public String leadId;

    @InvocableVariable(
      label='Id da Conta a reaproveitar'
      description='Em branco cria uma Conta nova a partir da empresa do lead.'
    )
    public String contaId;

    @InvocableVariable(
      label='Id do Contato a reaproveitar'
      description='Em branco cria um Contato novo.'
    )
    public String contatoId;
  }

  public class Resultado {
    @InvocableVariable(label='Convertido')
    public Boolean convertido;

    @InvocableVariable(label='Mensagem')
    public String mensagem;

    @InvocableVariable(label='Id da Conta')
    public String contaId;

    @InvocableVariable(label='Id do Contato')
    public String contatoId;

    @InvocableVariable(label='Id da Oportunidade')
    public String oportunidadeId;

    private Resultado(Boolean convertido, String mensagem) {
      this.convertido = convertido;
      this.mensagem = mensagem;
    }
  }

  @InvocableMethod(
    label='Converter Lead — Arnone Soluções'
    description='Converte o lead em Conta, Contato e Oportunidade do funil da Arnone Soluções, reaproveitando a Conta confirmada pelo usuário.'
    category='Arnone Soluções'
  )
  public static List<Resultado> converter(List<Pedido> pedidos) {
    List<Resultado> saida = new List<Resultado>();
    if (pedidos == null || pedidos.isEmpty()) {
      return saida;
    }
    for (Pedido p : pedidos) {
      saida.add(converterUm(p));
    }
    return saida;
  }

  private static Resultado converterUm(Pedido p) {
    Id leadId = (Id) p.leadId;
    List<Lead> achados;
    try {
      achados = Database.query(
        'SELECT ' + CAMPOS_LEAD + ' FROM Lead WHERE Id = :leadId'
      );
    } catch (QueryException e) {
      // Sem FLS nos campos da unidade a consulta nem chega a rodar: o campo
      // "não existe" para quem não tem permissão. Sem este tratamento o usuário
      // recebe uma exceção crua, que não diz que o problema é acesso.
      return new Resultado(false, SEM_PERMISSAO);
    }
    if (achados.isEmpty()) {
      return new Resultado(false, 'Lead não encontrado.');
    }
    Lead l = achados[0];

    // Os portões são conferidos de novo aqui. A tela pode ser pulada, o lead
    // pode ter mudado entre a preparação e o clique, e quem chama a classe
    // direto não passa por tela nenhuma.
    Map<Id, Integer> arquivos = arquivosPorLead(new Set<Id>{ l.Id });
    String impedimento = impedimentoPara(
      l,
      arquivos.containsKey(l.Id) ? arquivos.get(l.Id) : 0
    );
    if (impedimento != null) {
      return new Resultado(false, impedimento);
    }

    Savepoint sp = Database.setSavepoint();
    try {
      Account conta = prepararConta(l, p.contaId);

      Database.LeadConvert pedido = new Database.LeadConvert();
      pedido.setLeadId(l.Id);
      pedido.setConvertedStatus(statusConvertido());
      pedido.setAccountId(conta.Id);
      if (String.isNotBlank(p.contatoId)) {
        pedido.setContactId(p.contatoId);
      }
      pedido.setOpportunityName(l.SOL_Produto_Interesse__c + ' — ' + l.Company);
      pedido.setDoNotCreateOpportunity(false);

      Database.LeadConvertResult r = Database.convertLead(pedido, false);
      if (!r.isSuccess()) {
        Database.rollback(sp);
        return new Resultado(false, explicar(primeiroErro(r)));
      }

      String etapaFinal = avancarOportunidade(l, r.getOpportunityId());

      Resultado ok = new Resultado(
        true,
        'Lead convertido. ' +
          (p.contaId == null || String.isBlank(p.contaId)
            ? 'Conta criada: '
            : 'Conta reaproveitada: ') +
          conta.Name +
          '. A Oportunidade nasceu em "' +
          ETAPA_NASCIMENTO +
          '" e seguiu para "' +
          etapaFinal +
          '".'
      );
      ok.contaId = r.getAccountId();
      ok.contatoId = r.getContactId();
      ok.oportunidadeId = r.getOpportunityId();
      return ok;
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      // CLICKUP-9424 — o prazo total não pôde ser calculado. A conversão volta
      // ao ponto anterior ao savepoint: o Lead continua não convertido e a
      // Oportunidade não chega a existir. A mensagem diz o que corrigir.
      Database.rollback(sp);
      return new Resultado(false, CALENDARIO_INDISPONIVEL);
    } catch (Exception e) {
      Database.rollback(sp);
      return new Resultado(false, explicar(e.getMessage()));
    }
  }

  /**
   * Conta confirmada pelo usuário, ou nova. Ao reaproveitar, completa o que
   * falta em vez de sobrescrever: o CNPJ só é gravado se estiver vazio, e a
   * unidade é acrescentada à lista das que já atendem o cliente.
   */
  private static Account prepararConta(Lead l, String contaId) {
    if (String.isBlank(contaId)) {
      Account nova = new Account(
        Name = l.Company,
        CNPJ__c = l.CNPJ__c,
        Unidades_Atendidas__c = UNIDADE
      );
      // A regra de duplicidade padrão de Conta é um alerta na interface, mas em
      // Apex vira exceção. Aqui ela já cumpriu o papel dela: a tela mostrou ao
      // usuário a conta encontrada pelo CNPJ e ele escolheu criar uma nova.
      // Repetir o alerta só derrubaria a conversão depois da decisão tomada.
      Database.DMLOptions opcoes = new Database.DMLOptions();
      opcoes.duplicateRuleHeader.allowSave = true;
      Database.SaveResult r = Database.insert(nova, opcoes);
      if (!r.isSuccess()) {
        throw new ConversaoException(
          'Não foi possível criar a Conta: ' + r.getErrors()[0].getMessage()
        );
      }
      return nova;
    }

    Account atual = [
      SELECT Id, Name, CNPJ__c, Unidades_Atendidas__c
      FROM Account
      WHERE Id = :contaId
      LIMIT 1
    ];
    Boolean mudou = false;
    if (String.isBlank(atual.CNPJ__c)) {
      atual.CNPJ__c = l.CNPJ__c;
      mudou = true;
    }
    Set<String> unidades = new Set<String>();
    if (String.isNotBlank(atual.Unidades_Atendidas__c)) {
      unidades.addAll(atual.Unidades_Atendidas__c.split(';'));
    }
    if (!unidades.contains(UNIDADE)) {
      unidades.add(UNIDADE);
      atual.Unidades_Atendidas__c = String.join(
        new List<String>(unidades),
        ';'
      );
      mudou = true;
    }
    if (mudou) {
      update atual;
    }
    return atual;
  }

  /**
   * A Oportunidade nasce sem record type na conversão padrão, e numa etapa que
   * vem do value set org-wide. Aqui ela é trazida para o Funil_SOL e passa pela
   * etapa de nascimento antes de avançar — em duas gravações de propósito, para
   * que o histórico mostre por onde ela entrou.
   *
   * O destino depende do produto: Recuperação Tributária vai para o Diagnóstico
   * do e-CAC; ART 360 não tem diagnóstico e vai direto para a Negociação.
   */
  private static String avancarOportunidade(Lead l, Id oportunidadeId) {
    Opportunity nascimento = new Opportunity(
      Id = oportunidadeId,
      RecordTypeId = recordTypeId(Opportunity.SObjectType, RT_OPORTUNIDADE),
      StageName = ETAPA_NASCIMENTO,
      SOL_Produto_Negocio__c = l.SOL_Produto_Interesse__c
    );

    // CLICKUP-9424 — o prazo total de 30 dias úteis começa no contato efetivado
    // registrado no Lead. A data ORIGINAL é transportada para a Oportunidade
    // aqui, na conversão, e nunca é recalculada depois (nem por CreatedDate,
    // nem por mudança de etapa, nem por reatribuição). Vale para Recuperação
    // Tributária e ART 360.
    //
    // O limite é calculado ANTES de qualquer gravação: se o contato efetivado
    // existe e o calendário está indisponível, calcularPrazoTotal lança
    // CalendarioIndisponivelException e a conversão inteira é abortada no catch
    // de converterUm — nada é criado. A Oportunidade não pode nascer sem esse
    // prazo.
    Datetime inicioCiclo = l.SOL_Data_Contato_Efetivado__c;
    Datetime prazoTotal = inicioCiclo == null
      ? null
      : SOLPrazoTotalService.calcularPrazoTotal(inicioCiclo);

    update nascimento;

    // Os campos de prazo são SOMENTE LEITURA para o Comercial (FLS nos dois
    // permission sets). É a automação da conversão que os grava — em modo de
    // sistema, porque quem dispara a conversão não tem edição nesses campos
    // técnicos.
    //
    // CLICKUP-9439 / CLICKUP-9429 (absorvido) — a mesma gravação leva também os
    // seis campos da medição por etapa. É CÓPIA DIRETA, sem cálculo nenhum: não
    // consulta calendário, não conta dia útil e por isso NÃO introduz caminho de
    // falha novo na conversão.
    //
    // CONTRASTE DELIBERADO, e ele é o ponto: o prazo total acima é OPERACIONAL
    // — dispara a reatribuição de dono do CLICKUP-9424 —, e sem ele a
    // Oportunidade não pode nascer; por isso `calcularPrazoTotal` continua
    // ABORTANDO a conversão inteira quando o calendário falta. As durações são
    // ANALÍTICAS, e a política do P.O. para elas é a oposta: se não dá para
    // medir, o negócio segue e a medição fica pendente. Aqui as duas convivem
    // sem se misturar porque o transporte não calcula nada — se a duração
    // chegou vazia no Lead, chega vazia na Oportunidade, com a pendência junto,
    // e SOLDuracaoEtapaService a ressincroniza quando o Lead for corrigido.
    // A ORIGEM da etapa 1 vem por consulta ESTÁTICA, pelo motivo explicado na
    // constante de campos: em SOQL dinâmico ela derrubaria a conversão de quem
    // não tem PS_SOL_Distribuicao_Admin. Sem ela na Oportunidade, um recálculo
    // só da Oportunidade acharia a etapa 1 "sem origem" e APAGARIA a pendência
    // legítima herdada do Lead.
    Datetime distribuicao = SOLDuracaoEtapaService.distribuicaoDeLeads(
        new Set<Id>{ l.Id }
      )
      .get(l.Id);

    Opportunity tecnicos = new Opportunity(
      Id = oportunidadeId,
      SOL_Data_Distribuicao__c = distribuicao,
      SOL_Data_Primeira_Ligacao__c = l.SOL_Data_Primeira_Ligacao__c,
      SOL_Data_Reuniao_Procuracao__c = l.SOL_Data_Reuniao_Procuracao__c,
      SOL_Dias_Primeira_Ligacao__c = l.SOL_Dias_Primeira_Ligacao__c,
      SOL_Dias_Contato_Efetivado__c = l.SOL_Dias_Contato_Efetivado__c,
      SOL_Dias_Reuniao_Procuracao__c = l.SOL_Dias_Reuniao_Procuracao__c,
      // Pendência COMPLETA: checkbox, motivo e detalhe viajam juntos. Transportar
      // só o checkbox deixaria a Oportunidade nascer com uma lacuna marcada e
      // sem explicação nenhuma — pior do que não marcar, porque parece
      // informação.
      SOL_Duracao_Pendente__c = l.SOL_Duracao_Pendente__c == true,
      SOL_Duracao_Pendencia_Motivo__c = l.SOL_Duracao_Pendencia_Motivo__c,
      SOL_Duracao_Pendencia_Detalhe__c = l.SOL_Duracao_Pendencia_Detalhe__c
    );
    Boolean haMedicao =
      distribuicao != null ||
      l.SOL_Data_Primeira_Ligacao__c != null ||
      l.SOL_Data_Reuniao_Procuracao__c != null ||
      l.SOL_Dias_Primeira_Ligacao__c != null ||
      l.SOL_Dias_Contato_Efetivado__c != null ||
      l.SOL_Dias_Reuniao_Procuracao__c != null ||
      l.SOL_Duracao_Pendente__c == true;

    if (inicioCiclo != null) {
      tecnicos.SOL_Data_Inicio_Ciclo_Comercial__c = inicioCiclo;
      tecnicos.SOL_Prazo_Total_Comercial__c = prazoTotal;
    }

    // Sem contato efetivado E sem medição nenhuma no Lead não há o que
    // transportar: a gravação extra é evitada, como sempre foi.
    if (inicioCiclo != null || haMedicao) {
      Database.update(
        new List<Opportunity>{ tecnicos },
        AccessLevel.SYSTEM_MODE
      );
    }

    String destino = l.SOL_Produto_Interesse__c == PRODUTO_ART
      ? ETAPA_ART
      : ETAPA_RECUPERACAO;
    update new Opportunity(Id = oportunidadeId, StageName = destino);
    return destino;
  }

  private static String statusConvertidoCache;

  /**
   * O status de conversão não é fixo em código: qualquer valor marcado como
   * "convertido" no LeadStatus serve, e o cliente pode renomear o dele.
   */
  private static String statusConvertido() {
    if (statusConvertidoCache == null) {
      statusConvertidoCache = [
        SELECT MasterLabel
        FROM LeadStatus
        WHERE IsConverted = TRUE
        ORDER BY SortOrder NULLS LAST
        LIMIT 1
      ]
      .MasterLabel;
    }
    return statusConvertidoCache;
  }

  private static Id recordTypeId(Schema.SObjectType tipo, String nomeApi) {
    Schema.RecordTypeInfo info = tipo.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(nomeApi);
    if (info == null) {
      throw new ConversaoException(
        'Record type ' + nomeApi + ' não encontrado em ' + tipo
      );
    }
    return info.getRecordTypeId();
  }

  /**
   * Traduz o erro da plataforma para algo acionável. O caso que aparece de
   * verdade é a duplicidade de Contato: a conta reaproveitada já tem alguém com
   * os mesmos dados, e a regra padrão barra a criação de um segundo. A saída
   * não é forçar a gravação — é mandar o usuário escolher o contato que a tela
   * já ofereceu.
   */
  private static String explicar(String bruta) {
    if (bruta != null && bruta.containsIgnoreCase('duplicate')) {
      return 'A conta escolhida já tem um contato com estes dados. Volte uma tela e escolha o contato existente em vez de criar um novo.';
    }
    return 'A conversão falhou: ' + bruta;
  }

  private static String primeiroErro(Database.LeadConvertResult r) {
    return r.getErrors().isEmpty()
      ? 'motivo não informado pela plataforma'
      : r.getErrors()[0].getMessage();
  }

  public class ConversaoException extends Exception {
  }
}