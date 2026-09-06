/**
 * CLICKUP-9439 / CLICKUP-9429 (absorvido) — cálculo das durações por etapa da
 * jornada Arnone Soluções, em DIAS ÚTEIS.
 *
 * Seis etapas, seis intervalos, sempre `(origem, destino]`: a origem abre a
 * etapa e não conta, o destino a fecha e conta. Mesmo dia útil = 0 — que é um
 * valor GRAVADO, e não a mesma coisa que vazio.
 *
 *   1. distribuição            -> primeira ligação concluída       (Lead)
 *   2. primeira ligação        -> contato efetivado                (Lead e Opp)
 *   3. contato efetivado       -> o ÚLTIMO de reunião e procuração (Lead e Opp)
 *   4. solicitação do cálculo  -> recebimento do cálculo           (Opp)
 *   5. recebimento do cálculo  -> reunião final                    (Opp)
 *   6. reunião final           -> encerramento (Ganho/Perdido)     (Opp)
 *
 * ====================================================================
 * POR QUE ESTA CLASSE NUNCA RELANÇA — e por que isso NÃO é o antipadrão
 * ====================================================================
 * A regra do repositório é que "o Apex ignora" nunca é proteção: a porta
 * estrita de `SOLContatoEfetivadoInvocable` RELANÇA de propósito, porque lá
 * engolir deixaria um dado FALSO gravado — a tarefa afirmando que o lead
 * respondeu, sem lead nenhum efetivado.
 *
 * Aqui é o oposto exato, e é o único ponto do repositório onde engolir é o
 * comportamento correto. A decisão é do P.O. (Opção B — "marco sempre, duração
 * tolerante"):
 *
 *   - gravar o MARCO nunca precisa do calendário; só a CONTAGEM precisa;
 *   - a duração é medida ANALÍTICA, não regra de negócio: nenhuma venda pode
 *     ser abortada porque o Business Hours caiu;
 *   - engolir aqui não persiste nada falso — persiste VAZIO mais uma PENDÊNCIA
 *     explícita (`SOL_Duracao_Pendente__c` + motivo + detalhe), que é
 *     exatamente a diferença entre tolerância e falha silenciosa.
 *
 * Contraste deliberado com `SOL_ConverterLead` + `SOLPrazoTotalService.
 * calcularPrazoTotal`: aquele prazo é OPERACIONAL (dispara reatribuição de
 * dono), e sem ele a Oportunidade não pode nascer — lá a conversão inteira é
 * abortada quando o calendário falta. Políticas diferentes para naturezas
 * diferentes, por decisão, não por descuido.
 *
 * =========================================
 * O QUE NUNCA ACONTECE, e é garantido aqui
 * =========================================
 *   - duração NEGATIVA, ou ZERO por falta de marco ou por falha de cálculo;
 *   - sobrescrita de duração já consolidada — a primeira conclusão válida é
 *     congelada, então reprocessamento e reatribuição são inócuos;
 *   - pendência marcada por MARCO FALTANDO: etapa não concluída é vazia, não
 *     pendente;
 *   - exceção vazando para quem chamou.
 *
 * SEM GUARDA DE RECURSÃO, de propósito: a classe só escreve campos técnicos
 * novos, e nenhuma automação do repositório dispara com a mudança deles. Uma
 * guarda por transação pareceria prudente e faria mal — num lote que conclui
 * duas tarefas do mesmo registro, ela descartaria a segunda chamada e a etapa
 * dela ficaria sem duração até o Batch. Quem protege é a idempotência POR
 * ETAPA ("já preenchida, não recalcula"), que não tem esse efeito colateral.
 *
 * Bulk-safe: zero SOQL/DML em laço, e o calendário é consultado uma única vez
 * por transação (ver `ContadorDiasUteis`).
 */
public without sharing class SOLDuracaoEtapaService {
  /** Falha TRANSITÓRIA: é a única que o Batch reprocessa automaticamente. */
  public static final String MOTIVO_CALENDARIO = 'Calendário indisponível';

  /** DADO inválido: fora da varredura automática, exige correção das datas. */
  public static final String MOTIVO_INCONSISTENTE = 'Intervalo inconsistente';

  @TestVisible
  private static final String RT_SOL = 'SOL';

  /** Limite do campo de detalhe da pendência. */
  @TestVisible
  private static final Integer MAX_DETALHE = 255;

  /** Campos de pendência, iguais nos dois objetos. */
  private static final String CAMPO_PENDENTE = 'SOL_Duracao_Pendente__c';
  private static final String CAMPO_MOTIVO = 'SOL_Duracao_Pendencia_Motivo__c';
  private static final String CAMPO_DETALHE = 'SOL_Duracao_Pendencia_Detalhe__c';

  /**
   * Quantas vezes o acumulado de dias úteis foi montado nesta transação.
   *
   * Existe para o teste de BULK poder PROVAR — e não afirmar — que o calendário
   * é pré-computado uma vez por transação, e não uma vez por registro. Um lote
   * de 200 registros que produza mais de um acumulado teria voltado ao padrão
   * que estoura CPU time num backfill.
   */
  @TestVisible
  private static Integer contadoresMontados = 0;

  /** Somente testes: zera a instrumentação antes da chamada medida. */
  @TestVisible
  private static void zerarInstrumentacao() {
    contadoresMontados = 0;
  }

  /** Contagens controladas de uma execução. Nunca lança; só descreve. */
  public class ResultadoDuracao {
    public Integer avaliados = 0;
    public Integer foraDoEscopo = 0;
    public Integer calculadas = 0;
    public Integer pendentes = 0;
    public Integer jaPreenchidas = 0;
    public Integer ignoradas = 0;
    public Integer marcosConsolidados = 0;
    public Integer registrosAtualizados = 0;
    public Integer oportunidadesSincronizadas = 0;
    public Integer falhas = 0;

    public override String toString() {
      return 'avaliados=' +
        avaliados +
        ' foraDoEscopo=' +
        foraDoEscopo +
        ' calculadas=' +
        calculadas +
        ' pendentes=' +
        pendentes +
        ' jaPreenchidas=' +
        jaPreenchidas +
        ' ignoradas=' +
        ignoradas +
        ' marcosConsolidados=' +
        marcosConsolidados +
        ' registrosAtualizados=' +
        registrosAtualizados +
        ' oportunidadesSincronizadas=' +
        oportunidadesSincronizadas +
        ' falhas=' +
        falhas;
    }
  }

  /** Descritor de uma etapa: de onde, para onde, e onde grava. */
  private class Etapa {
    public String rotulo;
    public String campoOrigem;
    public Boolean origemEhDateTime;
    public String campoDestino;
    public Boolean destinoEhDateTime;
    public String campoDuracao;

    public Etapa(
      String rotulo,
      String campoOrigem,
      Boolean origemEhDateTime,
      String campoDestino,
      Boolean destinoEhDateTime,
      String campoDuracao
    ) {
      this.rotulo = rotulo;
      this.campoOrigem = campoOrigem;
      this.origemEhDateTime = origemEhDateTime;
      this.campoDestino = campoDestino;
      this.destinoEhDateTime = destinoEhDateTime;
      this.campoDuracao = campoDuracao;
    }
  }

  private static final List<Etapa> ETAPAS_LEAD = new List<Etapa>{
    new Etapa(
      '1 - Primeira ligação',
      'SOL_Data_Distribuicao__c',
      true,
      'SOL_Data_Primeira_Ligacao__c',
      true,
      'SOL_Dias_Primeira_Ligacao__c'
    ),
    new Etapa(
      '2 - Contato efetivado',
      'SOL_Data_Primeira_Ligacao__c',
      true,
      'SOL_Data_Contato_Efetivado__c',
      true,
      'SOL_Dias_Contato_Efetivado__c'
    ),
    new Etapa(
      '3 - Reunião e procuração',
      'SOL_Data_Contato_Efetivado__c',
      true,
      'SOL_Data_Reuniao_Procuracao__c',
      false,
      'SOL_Dias_Reuniao_Procuracao__c'
    )
  };

  /**
   * A etapa 1 NÃO está aqui, de propósito: a origem dela
   * (`Lead.SOL_Data_Distribuicao__c`) só existe no Lead. Na Oportunidade a
   * etapa 1 é sempre CÓPIA — transportada por `SOL_ConverterLead` na conversão
   * e ressincronizada depois por `sincronizarOportunidadesDeLeadsConvertidos`.
   * As etapas 2 e 3 aparecem aqui porque a Oportunidade tem os dois marcos de
   * cada uma e consegue recalcular sozinha se a cópia vier vazia.
   */
  private static final List<Etapa> ETAPAS_OPORTUNIDADE = new List<Etapa>{
    new Etapa(
      '2 - Contato efetivado',
      'SOL_Data_Primeira_Ligacao__c',
      true,
      'SOL_Data_Inicio_Ciclo_Comercial__c',
      true,
      'SOL_Dias_Contato_Efetivado__c'
    ),
    new Etapa(
      '3 - Reunião e procuração',
      'SOL_Data_Inicio_Ciclo_Comercial__c',
      true,
      'SOL_Data_Reuniao_Procuracao__c',
      false,
      'SOL_Dias_Reuniao_Procuracao__c'
    ),
    new Etapa(
      '4 - Cálculo jurídico',
      'SOL_Data_Solicitacao_Calculo__c',
      false,
      'SOL_Data_Recebimento_Calculo__c',
      false,
      'SOL_Dias_Calculo_Juridico__c'
    ),
    new Etapa(
      '5 - Reunião final',
      'SOL_Data_Recebimento_Calculo__c',
      false,
      'SOL_Data_Reuniao_Final__c',
      false,
      'SOL_Dias_Reuniao_Final__c'
    ),
    new Etapa(
      '6 - Fechamento',
      'SOL_Data_Reuniao_Final__c',
      false,
      'SOL_Data_Encerramento__c',
      true,
      'SOL_Dias_Fechamento__c'
    )
  };

  /** Espelhos Lead -> Oportunidade: os mesmos campos que a conversão leva. */
  private static final Map<String, String> ESPELHOS = new Map<String, String>{
    'SOL_Data_Primeira_Ligacao__c' => 'SOL_Data_Primeira_Ligacao__c',
    'SOL_Data_Reuniao_Procuracao__c' => 'SOL_Data_Reuniao_Procuracao__c',
    'SOL_Dias_Primeira_Ligacao__c' => 'SOL_Dias_Primeira_Ligacao__c',
    'SOL_Dias_Contato_Efetivado__c' => 'SOL_Dias_Contato_Efetivado__c',
    'SOL_Dias_Reuniao_Procuracao__c' => 'SOL_Dias_Reuniao_Procuracao__c'
  };

  // ==================================================================
  // API pública
  // ==================================================================

  /**
   * Consolida o marco da etapa 3, recalcula as etapas 1 a 3 dos Leads
   * informados e ressincroniza a Oportunidade dos que já foram convertidos.
   *
   * NUNCA lança: qualquer falha vira log e contagem no resultado.
   */
  public static ResultadoDuracao recalcularLeads(List<Id> leadIds) {
    ResultadoDuracao r = new ResultadoDuracao();
    Set<Id> ids = idsUteis(leadIds, Lead.SObjectType);
    if (ids.isEmpty()) {
      return r;
    }
    try {
      List<Lead> leads = [
        SELECT
          Id,
          IsConverted,
          ConvertedOpportunityId,
          SOL_Data_Distribuicao__c,
          SOL_Data_Primeira_Ligacao__c,
          SOL_Data_Contato_Efetivado__c,
          SOL_Data_Reuniao_Realizada__c,
          SOL_Data_Recebimento_Procuracao__c,
          SOL_Data_Reuniao_Procuracao__c,
          SOL_Dias_Primeira_Ligacao__c,
          SOL_Dias_Contato_Efetivado__c,
          SOL_Dias_Reuniao_Procuracao__c,
          SOL_Duracao_Pendente__c,
          SOL_Duracao_Pendencia_Motivo__c,
          SOL_Duracao_Pendencia_Detalhe__c
        FROM Lead
        WHERE Id IN :ids AND RecordType.DeveloperName = :RT_SOL
      ];
      r.foraDoEscopo += (ids.size() - leads.size());
      Set<Id> consolidados = consolidarMarcoDaEtapa3(leads, r);
      processar(leads, ETAPAS_LEAD, consolidados, r);
      sincronizarOportunidadesDeLeadsConvertidos(leads, r);
    } catch (Exception e) {
      registrarFalha('recalcularLeads', e, r);
    }
    return r;
  }

  /**
   * Recalcula as etapas 2 a 6 das Oportunidades informadas.
   *
   * NUNCA lança.
   */
  public static ResultadoDuracao recalcularOportunidades(List<Id> oppIds) {
    ResultadoDuracao r = new ResultadoDuracao();
    Set<Id> ids = idsUteis(oppIds, Opportunity.SObjectType);
    if (ids.isEmpty()) {
      return r;
    }
    try {
      List<Opportunity> opps = [
        SELECT
          Id,
          SOL_Data_Primeira_Ligacao__c,
          SOL_Data_Inicio_Ciclo_Comercial__c,
          SOL_Data_Reuniao_Procuracao__c,
          SOL_Data_Solicitacao_Calculo__c,
          SOL_Data_Recebimento_Calculo__c,
          SOL_Data_Reuniao_Final__c,
          SOL_Data_Encerramento__c,
          SOL_Dias_Primeira_Ligacao__c,
          SOL_Dias_Contato_Efetivado__c,
          SOL_Dias_Reuniao_Procuracao__c,
          SOL_Dias_Calculo_Juridico__c,
          SOL_Dias_Reuniao_Final__c,
          SOL_Dias_Fechamento__c,
          SOL_Duracao_Pendente__c,
          SOL_Duracao_Pendencia_Motivo__c,
          SOL_Duracao_Pendencia_Detalhe__c
        FROM Opportunity
        WHERE Id IN :ids AND RecordType.DeveloperName = :RT_SOL
      ];
      r.foraDoEscopo += (ids.size() - opps.size());
      processar(opps, ETAPAS_OPORTUNIDADE, new Set<Id>(), r);
    } catch (Exception e) {
      registrarFalha('recalcularOportunidades', e, r);
    }
    return r;
  }

  // ==================================================================
  // Núcleo
  // ==================================================================

  /**
   * Avalia todas as etapas de todos os registros do lote e grava uma vez só.
   *
   * Duas passadas de propósito. A primeira só DESCOBRE quais pares precisam ser
   * contados e qual é o intervalo global do lote; a segunda conta, já com o
   * calendário pré-computado. Sem isso, `BusinessHours.nextStartDate` seria
   * chamado uma vez por dia E por registro, e um backfill estouraria o CPU
   * time da transação.
   *
   * `jaAlterados` são os registros que a consolidação do marco da etapa 3 já
   * modificou em memória: eles precisam ser gravados mesmo que nenhuma duração
   * nova seja calculada, senão o marco recém-consolidado se perderia quando o
   * calendário estivesse fora.
   */
  private static void processar(
    List<SObject> registros,
    List<Etapa> etapas,
    Set<Id> jaAlterados,
    ResultadoDuracao r
  ) {
    if (registros.isEmpty()) {
      return;
    }
    r.avaliados += registros.size();
    Id bhId = SOLBusinessHoursHelper.businessHoursId();

    // Passada 1 — intervalo global, considerando apenas os pares SANOS. Um par
    // invertido ou absurdo não pode esticar o intervalo do lote inteiro.
    Date menor = null;
    Date maior = null;
    for (SObject reg : registros) {
      for (Etapa e : etapas) {
        if (reg.get(e.campoDuracao) != null) {
          continue;
        }
        Date origem = comoData(reg.get(e.campoOrigem), e.origemEhDateTime);
        Date destino = comoData(reg.get(e.campoDestino), e.destinoEhDateTime);
        if (origem == null || destino == null || destino < origem) {
          continue;
        }
        if (
          origem.daysBetween(destino) > SOLBusinessHoursHelper.MAX_DIAS_INTERVALO
        ) {
          continue;
        }
        if (menor == null || origem < menor) {
          menor = origem;
        }
        if (maior == null || destino > maior) {
          maior = destino;
        }
      }
    }

    ContadorDiasUteis contador = montarContador(bhId, menor, maior);

    // Passada 2 — contar e decidir a pendência de cada registro.
    List<SObject> paraAtualizar = new List<SObject>();
    for (SObject reg : registros) {
      List<String> pendencias = new List<String>();
      Boolean haTransitoria = false;
      Boolean haInconsistente = false;
      Boolean mudou = jaAlterados.contains((Id) reg.get('Id'));

      for (Etapa e : etapas) {
        if (reg.get(e.campoDuracao) != null) {
          // Requisitos 9 e 10: a primeira conclusão válida é congelada.
          r.jaPreenchidas++;
          continue;
        }
        Date origem = comoData(reg.get(e.campoOrigem), e.origemEhDateTime);
        Date destino = comoData(reg.get(e.campoDestino), e.destinoEhDateTime);
        if (origem == null || destino == null) {
          // Requisito 8: etapa NÃO CONCLUÍDA. Fica vazia, e isso não é
          // pendência — é etapa que ainda não aconteceu.
          r.ignoradas++;
          continue;
        }
        try {
          Integer dias = contar(bhId, contador, origem, destino);
          reg.put(e.campoDuracao, Decimal.valueOf(dias));
          mudou = true;
          r.calculadas++;
        } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException ex) {
          haTransitoria = true;
          pendencias.add(e.rotulo + ': calendário indisponível');
          r.pendentes++;
        } catch (SOLBusinessHoursHelper.IntervaloInvalidoException ex) {
          haInconsistente = true;
          pendencias.add(e.rotulo + ': intervalo inconsistente');
          r.pendentes++;
        }
      }

      if (aplicarPendencia(reg, pendencias, haTransitoria, haInconsistente)) {
        mudou = true;
      }
      if (mudou) {
        paraAtualizar.add(reg);
      }
    }

    gravar(paraAtualizar, r);
  }

  /**
   * Conta `(origem, destino]` pelo acumulado do lote quando ele cobre o par, e
   * pela régua dia a dia quando não cobre.
   *
   * O caminho dia a dia é também o que produz a exceção CERTA para os pares
   * que a passada 1 recusou: destino anterior à origem e distância acima do
   * teto voltam de `diasUteisEntre` como `IntervaloInvalidoException`, com a
   * mensagem que descreve o problema real.
   */
  private static Integer contar(
    Id bhId,
    ContadorDiasUteis contador,
    Date origem,
    Date destino
  ) {
    if (contador != null && contador.cobre(origem, destino)) {
      return contador.entre(origem, destino);
    }
    return SOLBusinessHoursHelper.diasUteisEntre(bhId, origem, destino);
  }

  /**
   * Marca, mantém ou limpa a pendência do registro. Devolve true se algum campo
   * de pendência mudou.
   *
   * PRECEDÊNCIA quando as duas situações coexistem no mesmo registro: vence a
   * TRANSITÓRIA. É ela que ainda pode se resolver sozinha, e o Batch só alcança
   * o registro por esse motivo; resolvida a transitória, a avaliação seguinte
   * rebaixa o motivo para inconsistente e o registro sai da varredura
   * automática — terminando o ciclo em vez de repeti-lo. A precedência
   * contrária prenderia a falha de calendário atrás de um dado ruim, para
   * sempre.
   */
  private static Boolean aplicarPendencia(
    SObject reg,
    List<String> pendencias,
    Boolean haTransitoria,
    Boolean haInconsistente
  ) {
    Boolean pendenteAgora = haTransitoria || haInconsistente;
    String motivoAgora = null;
    String detalheAgora = null;
    if (pendenteAgora) {
      motivoAgora = haTransitoria ? MOTIVO_CALENDARIO : MOTIVO_INCONSISTENTE;
      detalheAgora = String.join(pendencias, ' | ');
      if (detalheAgora.length() > MAX_DETALHE) {
        detalheAgora = detalheAgora.abbreviate(MAX_DETALHE);
      }
    }

    Boolean pendenteAntes = ((Boolean) reg.get(CAMPO_PENDENTE)) == true;
    String motivoAntes = (String) reg.get(CAMPO_MOTIVO);
    String detalheAntes = (String) reg.get(CAMPO_DETALHE);

    if (
      pendenteAntes == pendenteAgora &&
      motivoAntes == motivoAgora &&
      detalheAntes == detalheAgora
    ) {
      return false;
    }
    reg.put(CAMPO_PENDENTE, pendenteAgora);
    reg.put(CAMPO_MOTIVO, motivoAgora);
    reg.put(CAMPO_DETALHE, detalheAgora);
    return true;
  }

  /**
   * Etapa 3: materializa "o ÚLTIMO dos dois marcos" no Lead, em memória.
   *
   * Só grava quando os DOIS existem — com um marco só a etapa não terminou, e
   * registrar o marco isolado inventaria uma conclusão que não houve. Não
   * sobrescreve o que já está gravado.
   *
   * O DateTime da reunião é normalizado para a DATA em America/Sao_Paulo antes
   * da comparação: comparar DateTime com Date direto erra o fuso em até um dia,
   * porque uma reunião às 23:30 de São Paulo já é o dia seguinte em GMT.
   *
   * Devolve os Ids alterados para que `processar` os grave mesmo que nenhuma
   * duração nova saia daquela passada.
   */
  private static Set<Id> consolidarMarcoDaEtapa3(
    List<Lead> leads,
    ResultadoDuracao r
  ) {
    Set<Id> alterados = new Set<Id>();
    for (Lead l : leads) {
      if (l.SOL_Data_Reuniao_Procuracao__c != null) {
        continue;
      }
      if (
        l.SOL_Data_Reuniao_Realizada__c == null ||
        l.SOL_Data_Recebimento_Procuracao__c == null
      ) {
        continue;
      }
      Date reuniao = SOLBusinessHoursHelper.dataEm(
        l.SOL_Data_Reuniao_Realizada__c,
        SOLBusinessHoursHelper.TZ_SAO_PAULO
      );
      Date procuracao = l.SOL_Data_Recebimento_Procuracao__c;
      l.SOL_Data_Reuniao_Procuracao__c = reuniao > procuracao
        ? reuniao
        : procuracao;
      alterados.add(l.Id);
      r.marcosConsolidados++;
    }
    return alterados;
  }

  /**
   * Leva para a Oportunidade os valores das etapas 1 a 3 dos Leads já
   * convertidos, SEMPRE sem sobrescrever o que a Oportunidade já tem.
   *
   * Por que existe: `SOL_ConverterLead` transporta esses campos no instante da
   * conversão. Se naquele instante o calendário estivesse fora, a Oportunidade
   * nasceria sem as etapas 1 a 3 e nunca mais as teria — a etapa 1 não pode ser
   * recalculada na Oportunidade, porque a origem dela só existe no Lead. Esta
   * ressincronização é o que fecha esse buraco depois que o Batch conserta o
   * Lead, e é o que faz o relatório cobrir Lead e Oportunidade sem perder o que
   * aconteceu antes da conversão.
   */
  private static void sincronizarOportunidadesDeLeadsConvertidos(
    List<Lead> leads,
    ResultadoDuracao r
  ) {
    Map<Id, Lead> porOportunidade = new Map<Id, Lead>();
    for (Lead l : leads) {
      if (l.IsConverted != true || l.ConvertedOpportunityId == null) {
        continue;
      }
      // Se dois Leads apontarem para a mesma Oportunidade, vence o de menor Id
      // — critério determinístico, para que rodar duas vezes dê o mesmo
      // resultado.
      Lead atual = porOportunidade.get(l.ConvertedOpportunityId);
      if (atual == null || l.Id < atual.Id) {
        porOportunidade.put(l.ConvertedOpportunityId, l);
      }
    }
    if (porOportunidade.isEmpty()) {
      return;
    }

    List<Opportunity> paraAtualizar = new List<Opportunity>();
    for (Opportunity o : [
      SELECT
        Id,
        SOL_Data_Primeira_Ligacao__c,
        SOL_Data_Reuniao_Procuracao__c,
        SOL_Dias_Primeira_Ligacao__c,
        SOL_Dias_Contato_Efetivado__c,
        SOL_Dias_Reuniao_Procuracao__c
      FROM Opportunity
      WHERE Id IN :porOportunidade.keySet()
    ]) {
      Lead l = porOportunidade.get(o.Id);
      Boolean mudou = false;
      for (String campoLead : ESPELHOS.keySet()) {
        String campoOpp = ESPELHOS.get(campoLead);
        if (o.get(campoOpp) != null || l.get(campoLead) == null) {
          continue;
        }
        o.put(campoOpp, l.get(campoLead));
        mudou = true;
      }
      if (mudou) {
        paraAtualizar.add(o);
      }
    }
    if (paraAtualizar.isEmpty()) {
      return;
    }
    r.oportunidadesSincronizadas += paraAtualizar.size();
    gravar(paraAtualizar, r);
  }

  // ==================================================================
  // Contagem de dias úteis
  // ==================================================================

  /**
   * Acumulado de dias úteis do intervalo global do lote, para contar qualquer
   * par em memória.
   *
   * Não é régua paralela: os dias úteis vêm de
   * `SOLBusinessHoursHelper.diasUteisNoIntervalo`, que por sua vez usa
   * `aberturaDoDia`. Aqui só se INDEXA a resposta da régua, para não perguntar
   * a mesma coisa milhares de vezes.
   */
  private class ContadorDiasUteis {
    private Date inicio;
    private Date fim;
    private List<Integer> acumulado;

    public ContadorDiasUteis(Id bhId, Date de, Date ate) {
      Set<Date> uteis = SOLBusinessHoursHelper.diasUteisNoIntervalo(
        bhId,
        de,
        ate
      );
      this.inicio = de;
      this.fim = ate;
      this.acumulado = new List<Integer>();
      Integer total = 0;
      Date dia = de;
      while (dia <= ate) {
        if (uteis.contains(dia)) {
          total++;
        }
        acumulado.add(total);
        dia = dia.addDays(1);
      }
    }

    /** O acumulado sabe responder por este par? */
    public Boolean cobre(Date origem, Date destino) {
      return destino >= origem && origem >= inicio && destino <= fim;
    }

    /** Dias úteis em `(origem, destino]`. Só use depois de `cobre`. */
    public Integer entre(Date origem, Date destino) {
      return acumulado[inicio.daysBetween(destino)] -
        acumulado[inicio.daysBetween(origem)];
    }
  }

  /**
   * Monta o acumulado do lote, ou devolve null quando não dá: sem calendário,
   * sem nenhum par sano para contar, ou intervalo global maior que o teto da
   * régua. Com null, `processar` volta a contar par a par — mais caro, porém
   * correto, e apenas no caso patológico de um lote com marcos separados por
   * mais de uma década.
   */
  private static ContadorDiasUteis montarContador(
    Id bhId,
    Date menor,
    Date maior
  ) {
    if (bhId == null || menor == null || maior == null) {
      return null;
    }
    if (menor.daysBetween(maior) > SOLBusinessHoursHelper.MAX_DIAS_INTERVALO) {
      return null;
    }
    try {
      contadoresMontados++;
      return new ContadorDiasUteis(bhId, menor, maior);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'SOLDuracaoEtapaService: pré-cálculo do calendário indisponível (' +
          e.getTypeName() +
          '); a contagem seguirá par a par. ' +
          e.getMessage()
      );
      return null;
    }
  }

  // ==================================================================
  // Utilitários
  // ==================================================================

  /** Data em São Paulo do valor bruto do campo — um Date passa direto. */
  private static Date comoData(Object valor, Boolean ehDateTime) {
    if (valor == null) {
      return null;
    }
    if (ehDateTime) {
      return SOLBusinessHoursHelper.dataEm(
        (Datetime) valor,
        SOLBusinessHoursHelper.TZ_SAO_PAULO
      );
    }
    return (Date) valor;
  }

  /** Ids não nulos e do SObject esperado. O resto é descartado em silêncio. */
  private static Set<Id> idsUteis(List<Id> ids, Schema.SObjectType tipo) {
    Set<Id> saida = new Set<Id>();
    if (ids == null) {
      return saida;
    }
    for (Id i : ids) {
      if (i != null && i.getSObjectType() == tipo) {
        saida.add(i);
      }
    }
    return saida;
  }

  /**
   * Gravação em modo de SISTEMA e com sucesso parcial.
   *
   * Modo de sistema porque são campos técnicos que ninguém edita — FLS somente
   * leitura nos dois permission sets — e quem dispara a automação não tem
   * permissão de escrita neles. Sucesso parcial porque a falha de um registro
   * não pode derrubar a medição dos outros nem a operação comercial que
   * originou a chamada.
   */
  private static void gravar(List<SObject> registros, ResultadoDuracao r) {
    if (registros == null || registros.isEmpty()) {
      return;
    }
    List<Database.SaveResult> resultados = Database.update(
      registros,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < resultados.size(); i++) {
      if (resultados[i].isSuccess()) {
        r.registrosAtualizados++;
        continue;
      }
      r.falhas++;
      System.debug(
        LoggingLevel.ERROR,
        'SOLDuracaoEtapaService: falha ao gravar duração em ' +
          registros[i].get('Id') +
          ' -> ' +
          resultados[i].getErrors()
      );
    }
  }

  private static void registrarFalha(
    String origem,
    Exception e,
    ResultadoDuracao r
  ) {
    r.falhas++;
    System.debug(
      LoggingLevel.ERROR,
      'SOLDuracaoEtapaService.' +
        origem +
        ': ' +
        e.getTypeName() +
        ': ' +
        e.getMessage() +
        ' | ' +
        e.getStackTraceString()
    );
  }
}
