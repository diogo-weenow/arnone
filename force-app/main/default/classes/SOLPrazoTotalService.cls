/**
 * CLICKUP-9424 — Card 13 — Reatribuição automática por estouro do prazo total
 * de 30 dias.
 *
 * A régua é a MESMA dos demais prazos da jornada (PDF: "os '30 dias' devem
 * seguir a mesma régua dos demais prazos deste processo"): 30 dias ÚTEIS por
 * SOLBusinessHoursHelper — calendário oficial da org, feriados e timezone
 * America/Sao_Paulo. Nada de dias corridos, nada de grade fixa seg–sex.
 *
 * ORIGEM DO PRAZO: Opportunity.SOL_Data_Inicio_Ciclo_Comercial__c, que
 * SOL_ConverterLead copia de Lead.SOL_Data_Contato_Efetivado__c na conversão.
 * O limite fica em Opportunity.SOL_Prazo_Total_Comercial__c. NENHUM dos dois é
 * recalculado a partir de CreatedDate, mudança de etapa ou reatribuição — este
 * serviço apenas LÊ os dois campos. Sem data de início não há inferência
 * silenciosa: a Oportunidade é simplesmente ignorada.
 *
 * QUANDO O PRAZO VENCE e a Oportunidade continua ABERTA (Ganho e Perdido têm
 * IsClosed = true e nunca entram), para Record Type SOL e produto
 * "Recuperação Tributária" ou "ART 360":
 *  - transfere a Oportunidade ao próximo vendedor elegível da Fila_Leads_SOL,
 *    EXCLUINDO o proprietário atual da escolha;
 *  - transfere ao novo vendedor todas as Tasks ainda ABERTAS da Oportunidade
 *    (IsClosed = false); Tasks concluídas/canceladas ficam intactas;
 *  - registra data, motivo e quantidade da reatribuição;
 *  - roda UMA única vez por Oportunidade (SOL_Qtd_Reatribuicoes_Prazo__c > 0
 *    marca como processada);
 *  - preserva etapa, campos, datas, marcos e histórico — não cria tarefas nem
 *    reinicia prazos.
 *
 * O vendedor anterior CONTINUA na rotação de novos Leads: nada é removido da
 * fila; só o ponteiro global avança.
 *
 * SEM OUTRO VENDEDOR ATIVO: o proprietário NÃO é alterado e a Oportunidade NÃO
 * é marcada como processada (a contagem não é incrementada). Fica registrada a
 * situação controlada em SOL_Status_Reatribuicao_Prazo__c = "Sem outro
 * vendedor" e a próxima execução do Batch tenta de novo.
 *
 * REAPROVEITA a fila, o roster de usuários diretos ativos, o ponteiro global e a
 * seleção round-robin de SOLDistribuicaoService (bloquearSingleton,
 * localizarFilaValida, obterMembrosDiretosAtivos, indiceDe,
 * proximoVendedorExcluindo) — o algoritmo NÃO é duplicado. Respeita o
 * kill-switch do singleton (Ativo__c = false ⇒ nada é tocado).
 *
 * CONCORRÊNCIA E ATOMICIDADE: o singleton é travado com FOR UPDATE (serializa
 * com a distribuição inicial e com a reatribuição por falta de contato) e as
 * Oportunidades e Tasks também são lidas com FOR UPDATE. Um Savepoint envolve
 * toda a execução: proprietário, Tasks abertas, auditoria e ponteiro nunca
 * ficam parcialmente atualizados. A atualização das Oportunidades usa
 * allOrNone = false para que uma Opp inválida não bloqueie as demais; o
 * ponteiro só reflete a última troca EFETIVADA.
 *
 * NÃO altera proprietário de Conta nem de Contato. NÃO antecipa o CLICKUP-9425.
 */
public without sharing class SOLPrazoTotalService {
  /** Régua do prazo total: 30 dias ÚTEIS. */
  public static final Integer DIAS_UTEIS_PRAZO_TOTAL = 30;

  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String PRODUTO_ART = 'ART 360';
  @TestVisible
  private static final Set<String> PRODUTOS_NO_ESCOPO = new Set<String>{
    'Recuperação Tributária',
    'ART 360'
  };
  @TestVisible
  private static final String STATUS_REATRIBUIDO = 'Reatribuido';
  @TestVisible
  private static final String STATUS_SEM_OUTRO_VENDEDOR = 'Sem outro vendedor';

  /** Motivo registrado na Oportunidade reatribuída. */
  public static final String MOTIVO_PRAZO_TOTAL = 'Estouro do prazo total de 30 dias úteis do ciclo comercial';
  /** Situação controlada quando não há outro vendedor ativo na fila. */
  public static final String MOTIVO_SEM_OUTRO_VENDEDOR = 'Prazo total vencido, mas não havia outro vendedor ativo disponível na fila.';

  /** Mensagens controladas de falha (o Batch registra, não propaga ao usuário). */
  public static final String MSG_CONFIG = 'A reatribuição por prazo total está temporariamente indisponível (fila/estado). Acione o administrador.';
  public static final String MSG_ERRO_GENERICO = 'A reatribuição por prazo total não pôde ser concluída agora. As Oportunidades serão reavaliadas na próxima varredura.';

  /** Resultado controlado da varredura. */
  public class ResultadoPrazoTotal {
    /** Oportunidades que trocaram de proprietário agora. */
    public Integer reatribuidas = 0;
    /** Tasks abertas transferidas ao novo proprietário. */
    public Integer tarefasTransferidas = 0;
    /** Prazo vencido, mas sem outro vendedor ativo — não marcadas como processadas. */
    public Integer semOutroVendedor = 0;
    /** Fora de escopo, prazo não vencido, fechadas ou já processadas. */
    public Integer ignoradas = 0;
    /** Oportunidades que falharam na gravação (reavaliadas na próxima varredura). */
    public Integer comErro = 0;
    public List<String> mensagens = new List<String>();
  }

  /**
   * Limite de 30 dias ÚTEIS a partir de `inicio`, pela régua compartilhada.
   *
   * @throws SOLBusinessHoursHelper.CalendarioIndisponivelException calendário
   *   ausente/inativo — o chamador decide se aborta ou apenas não grava o prazo.
   */
  public static Datetime calcularPrazoTotal(Datetime inicio) {
    if (inicio == null) {
      return null;
    }
    return SOLBusinessHoursHelper.prazoEmDiasUteis(
      SOLBusinessHoursHelper.businessHoursId(),
      inicio,
      DIAS_UTEIS_PRAZO_TOTAL
    );
  }

  /**
   * Reatribui, em round-robin, as Oportunidades SOL cujo prazo total de 30 dias
   * úteis venceu e que continuam abertas.
   *
   * @param opportunityIds Ids candidatos (qualquer origem; filtrados aqui).
   * @return contagens controladas — nunca lança para o chamador.
   */
  public static ResultadoPrazoTotal reatribuirPorPrazoTotal(List<Id> opportunityIds) {
    ResultadoPrazoTotal r = new ResultadoPrazoTotal();
    if (opportunityIds == null || opportunityIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>();
    for (Id oid : opportunityIds) {
      if (oid != null && oid.getSObjectType() == Opportunity.SObjectType) {
        ids.add(oid);
      }
    }
    if (ids.isEmpty()) {
      return r;
    }

    Datetime agora = System.now();
    Savepoint sp = Database.setSavepoint();
    try {
      // Mesmo lock da distribuição inicial e da reatribuição por falta de
      // contato: serializa o avanço do ponteiro entre transações concorrentes.
      SOL_Distribuicao_Estado__c estado = SOLDistribuicaoService.bloquearSingleton();

      List<Opportunity> carregadas = [
        SELECT
          Id,
          OwnerId,
          StageName,
          IsClosed,
          SOL_Produto_Negocio__c,
          RecordType.DeveloperName,
          SOL_Data_Inicio_Ciclo_Comercial__c,
          SOL_Prazo_Total_Comercial__c,
          SOL_Qtd_Reatribuicoes_Prazo__c,
          SOL_Status_Reatribuicao_Prazo__c
        FROM Opportunity
        WHERE Id IN :ids
        FOR UPDATE
      ];

      List<Opportunity> candidatas = new List<Opportunity>();
      Set<Id> encontradas = new Set<Id>();
      for (Opportunity o : carregadas) {
        encontradas.add(o.Id);
        Boolean noEscopo =
          o.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          PRODUTOS_NO_ESCOPO.contains(o.SOL_Produto_Negocio__c) &&
          // Ganho e Perdido têm IsClosed = true: nunca são reatribuídas.
          o.IsClosed == false &&
          // Sem data de início ou sem prazo calculado: nenhuma inferência.
          o.SOL_Data_Inicio_Ciclo_Comercial__c != null &&
          o.SOL_Prazo_Total_Comercial__c != null &&
          // No limite JÁ reatribui (<=), antes do limite não.
          o.SOL_Prazo_Total_Comercial__c <= agora &&
          // Uma única vez por Oportunidade.
          (o.SOL_Qtd_Reatribuicoes_Prazo__c == null ||
          o.SOL_Qtd_Reatribuicoes_Prazo__c <= 0);
        if (noEscopo) {
          candidatas.add(o);
        } else {
          r.ignoradas++;
        }
      }
      r.ignoradas += (ids.size() - encontradas.size());

      if (candidatas.isEmpty()) {
        return r;
      }

      // Kill-switch desligado: a reatribuição por prazo também para.
      if (!estado.Ativo__c) {
        r.ignoradas += candidatas.size();
        return r;
      }

      // Roster: mesmos membros diretos ativos da Fila_Leads_SOL.
      List<User> ativos;
      try {
        ativos = SOLDistribuicaoService.obterMembrosDiretosAtivos(
          SOLDistribuicaoService.localizarFilaValida().Id
        );
      } catch (SOLDistribuicaoService.RosterVazioException e) {
        ativos = new List<User>();
      }
      Integer n = ativos.size();

      // Ponto de partida: o próximo após o ponteiro global (User.Id ASC).
      Integer cursor = 0;
      if (n > 0 && estado.Ultimo_Usuario__c != null) {
        Integer k = SOLDistribuicaoService.indiceDe(ativos, estado.Ultimo_Usuario__c);
        cursor = (k >= 0) ? Math.mod(k + 1, n) : 0;
      }

      List<Opportunity> paraAtualizar = new List<Opportunity>();
      List<Id> ordemReatribuidas = new List<Id>();
      Map<Id, Id> novoDonoPorOpp = new Map<Id, Id>();
      List<Opportunity> semVendedor = new List<Opportunity>();

      for (Opportunity o : candidatas) {
        Id escolhido = n == 0
          ? null
          : SOLDistribuicaoService.proximoVendedorExcluindo(ativos, cursor, o.OwnerId);

        if (escolhido == null) {
          // Não altera proprietário e NÃO marca como processada: a contagem
          // fica intacta e a Oportunidade volta na próxima varredura.
          semVendedor.add(
            new Opportunity(
              Id = o.Id,
              SOL_Status_Reatribuicao_Prazo__c = STATUS_SEM_OUTRO_VENDEDOR,
              SOL_Motivo_Reatribuicao_Prazo__c = MOTIVO_SEM_OUTRO_VENDEDOR
            )
          );
          r.semOutroVendedor++;
          continue;
        }

        // Consome o ponteiro: avança para depois do vendedor escolhido.
        cursor = Math.mod(SOLDistribuicaoService.indiceDe(ativos, escolhido) + 1, n);

        paraAtualizar.add(
          new Opportunity(
            Id = o.Id,
            OwnerId = escolhido,
            SOL_Qtd_Reatribuicoes_Prazo__c =
              (o.SOL_Qtd_Reatribuicoes_Prazo__c == null
                ? 0
                : o.SOL_Qtd_Reatribuicoes_Prazo__c) + 1,
            SOL_Data_Reatribuicao_Prazo__c = agora,
            SOL_Motivo_Reatribuicao_Prazo__c = MOTIVO_PRAZO_TOTAL,
            SOL_Status_Reatribuicao_Prazo__c = STATUS_REATRIBUIDO
          )
          // Etapa, marcos, datas e o próprio prazo NÃO são tocados.
        );
        ordemReatribuidas.add(o.Id);
        novoDonoPorOpp.put(o.Id, escolhido);
      }

      // Situações controladas (sem outro vendedor): all-or-none, sem ponteiro.
      if (!semVendedor.isEmpty()) {
        update semVendedor;
      }

      Set<Id> oppsOk = new Set<Id>();
      if (!paraAtualizar.isEmpty()) {
        // allOrNone = false: uma Opp inválida não bloqueia as demais do lote.
        Database.SaveResult[] resultados = Database.update(paraAtualizar, false);
        for (Integer i = 0; i < resultados.size(); i++) {
          if (resultados[i].isSuccess()) {
            oppsOk.add(paraAtualizar[i].Id);
          } else {
            r.comErro++;
            System.debug(
              LoggingLevel.ERROR,
              'SOLPrazoTotalService: falha ao reatribuir ' +
                paraAtualizar[i].Id +
                ': ' +
                resultados[i].getErrors()
            );
          }
        }
        r.reatribuidas = oppsOk.size();
      }

      // Tasks ABERTAS das Oportunidades que realmente trocaram de dono.
      // Concluídas/canceladas (IsClosed = true) ficam intactas.
      if (!oppsOk.isEmpty()) {
        List<Task> abertas = [
          SELECT Id, WhatId, OwnerId
          FROM Task
          WHERE WhatId IN :oppsOk AND IsClosed = false
          FOR UPDATE
        ];
        List<Task> transferir = new List<Task>();
        for (Task t : abertas) {
          Id novoDono = novoDonoPorOpp.get(t.WhatId);
          if (novoDono != null && t.OwnerId != novoDono) {
            transferir.add(new Task(Id = t.Id, OwnerId = novoDono));
          }
        }
        if (!transferir.isEmpty()) {
          // All-or-none: se falhar, o Savepoint desfaz também a troca de dono
          // das Oportunidades — nada fica parcialmente atualizado.
          update transferir;
          r.tarefasTransferidas = transferir.size();
        }
      }

      // Ponteiro: última troca EFETIVADA, na ordem de processamento.
      Id ponteiroNovo = estado.Ultimo_Usuario__c;
      for (Id oppId : ordemReatribuidas) {
        if (oppsOk.contains(oppId)) {
          ponteiroNovo = novoDonoPorOpp.get(oppId);
        }
      }
      if (ponteiroNovo != estado.Ultimo_Usuario__c) {
        estado.Ultimo_Usuario__c = ponteiroNovo;
        estado.Data_Ultima_Distribuicao__c = agora;
        update estado;
      }

      return r;
    } catch (SOLDistribuicaoService.DistribuicaoException e) {
      Database.rollback(sp);
      System.debug(LoggingLevel.ERROR, 'SOLPrazoTotalService: ' + e.getMessage());
      ResultadoPrazoTotal erro = new ResultadoPrazoTotal();
      erro.comErro = ids.size();
      erro.mensagens.add(MSG_CONFIG);
      return erro;
    } catch (Exception e) {
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'SOLPrazoTotalService: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      ResultadoPrazoTotal erro = new ResultadoPrazoTotal();
      erro.comErro = ids.size();
      erro.mensagens.add(MSG_ERRO_GENERICO);
      return erro;
    }
  }
}
