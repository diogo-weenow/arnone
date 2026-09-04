/**
 * CLICKUP-9425 — Entrada da PERDA no Lead (antes da conversão).
 *
 * Camada fina entre o Record-Triggered Flow SOL_Encerrar_Tarefas_Lead_Perdido
 * (after-save em Lead) e SOLNegocioPerdidoService.encerrarPorLeadPerdido.
 * NÃO duplica lógica, não faz SOQL nem DML.
 *
 * Falha ATÔMICA: se o cancelamento das Tasks falhar, a exceção controlada é
 * RELANÇADA para o Flow. Como o Flow chama esta ação com flowTransactionModel =
 * CurrentTransaction, a exceção aborta a própria desqualificação do Lead — não
 * fica negócio perdido com tarefa aberta sobrando.
 */
public with sharing class SOLNegocioPerdidoLeadInvocable {
  public class Entrada {
    @InvocableVariable(
      label='Id do Lead'
      description='Lead desqualificado com motivo "Negócio perdido" e sem opt-out.'
      required=true
    )
    public Id leadId;
  }

  @InvocableMethod(
    label='Encerrar tarefas do lead perdido SOL'
    description='Consolida os Ids recebidos e chama SOLNegocioPerdidoService.encerrarPorLeadPerdido uma única vez por execução bulk.'
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
        entrada.leadId != null &&
        entrada.leadId.getSObjectType() == Lead.SObjectType
      ) {
        ids.add(entrada.leadId);
      }
    }
    if (ids.isEmpty()) {
      return;
    }

    try {
      SOLNegocioPerdidoService.encerrarPorLeadPerdido(new List<Id>(ids));
    } catch (SOLNegocioPerdidoService.NegocioPerdidoException e) {
      System.debug(LoggingLevel.ERROR, 'SOLNegocioPerdidoLeadInvocable: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'SOLNegocioPerdidoLeadInvocable: ' + e.getTypeName() + ': ' + e.getMessage()
      );
      throw new SOLNegocioPerdidoService.NegocioPerdidoException(
        SOLNegocioPerdidoService.MSG_FALHA_LEAD
      );
    }
  }
}
