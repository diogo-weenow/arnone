/**
 * CLICKUP-9425 — Entrada da PERDA na Oportunidade (depois da conversão).
 *
 * Camada fina entre o Record-Triggered Flow
 * SOL_Encerrar_Tarefas_Oportunidade_Perdida (after-save em Opportunity) e
 * SOLNegocioPerdidoService.encerrarPorOportunidadePerdida. NÃO duplica lógica,
 * não faz SOQL nem DML.
 *
 * Automação SEPARADA da do Lead de propósito: objetos diferentes, gatilhos
 * diferentes, entradas diferentes no serviço.
 *
 * Falha ATÔMICA: se o cancelamento das Tasks falhar, a exceção controlada é
 * RELANÇADA para o Flow. Com flowTransactionModel = CurrentTransaction, isso
 * aborta a própria mudança da Oportunidade para "Perdido".
 */
public with sharing class SOLNegocioPerdidoOportunidadeInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id da Oportunidade'
      description='Oportunidade que virou "Perdido".'
      required=true
    )
    public Id opportunityId;
  }

  @InvocableMethod(
    label='Encerrar tarefas da Oportunidade perdida SOL'
    description='Consolida os Ids recebidos e chama SOLNegocioPerdidoService.encerrarPorOportunidadePerdida uma única vez por execução bulk.'
    category='Arnone Soluções'
  )
  public static void encerrar(List<Entrada> entradas) {
    if (entradas == null || entradas.isEmpty()) {
      return;
    }

    Set<Id> ids = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (
        entrada != null &&
        entrada.opportunityId != null &&
        entrada.opportunityId.getSObjectType() == Opportunity.SObjectType
      ) {
        ids.add(entrada.opportunityId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }

    try {
      SOLNegocioPerdidoService.encerrarPorOportunidadePerdida(new List<Id>(ids));
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      System.debug(LoggingLevel.ERROR, 'SOLNegocioPerdidoOportunidadeInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLNegocioPerdidoOportunidadeInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLNegocioPerdidoService.NegocioPerdidoException(
        SOLNegocioPerdidoService.MSG_FALHA_OPORTUNIDADE
      );
    }
  }
}
